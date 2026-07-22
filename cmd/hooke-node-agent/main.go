package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/config"
	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/internal/transport"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	cluster := config.String("HOOKE_CLUSTER_ID", "")
	runID := config.String("HOOKE_ACTIVE_RUN_ID", "")
	node := config.String("NODE_NAME", "")
	if cluster == "" || node == "" {
		logger.Error("HOOKE_CLUSTER_ID and NODE_NAME are required")
		os.Exit(2)
	}
	client := transport.NewClient(config.String("HOOKE_INGESTER_URL", "http://hooke-ingester.hooke-system.svc:8080"), config.String("HOOKE_AUTH_TOKEN", ""))
	interval := config.Duration("HOOKE_AGENT_HEALTH_INTERVAL", 30*time.Second)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	started := time.Now()
	emit := func() {
		if runID == "" {
			runID = config.String("HOOKE_ACTIVE_RUN_ID", "")
		}
		if runID == "" {
			return
		}
		var mem runtime.MemStats
		runtime.ReadMemStats(&mem)
		health := event.New(cluster, runID, event.CollectorHealth, "hooke-node-agent", time.Now())
		health.NodeName = node
		health.SourceInstance = node
		health.Attributes = map[string]any{"uptime_seconds": time.Since(started).Seconds(), "goroutines": runtime.NumGoroutine(), "heap_alloc_bytes": mem.HeapAlloc, "go_version": runtime.Version(), "os": runtime.GOOS, "arch": runtime.GOARCH}

		before := time.Now().UTC()
		after := time.Now().UTC()
		source := before.Add(after.Sub(before) / 2)
		bracketUncertainty := after.Sub(before).Nanoseconds()/2 + 1
		clockSample := event.New(cluster, runID, event.ClockSyncSample, "hooke-node-agent", source)
		clockSample.NodeName = node
		clockSample.SourceInstance = node
		clockSample.ClockUncertaintyNS = &bracketUncertainty
		clockSample.Attributes = map[string]any{
			"sample_kind": "realtime-bracket", "reference": "node-local-utc",
			"offset_status": "unknown", "bracket_start_ns": before.UnixNano(), "bracket_end_ns": after.UnixNano(),
		}
		if offset, ok := config.OptionalInt64("HOOKE_CLOCK_OFFSET_NS"); ok {
			clockSample.ClockOffsetNS = &offset
			clockSample.EventTimeNS = clockSample.SourceTimeNS + offset
			clockSample.Attributes["offset_status"] = "externally-measured"
		}
		if uncertainty, ok := config.OptionalInt64("HOOKE_CLOCK_UNCERTAINTY_NS"); ok && uncertainty >= 0 {
			clockSample.ClockUncertaintyNS = &uncertainty
			clockSample.Attributes["uncertainty_status"] = "externally-measured"
		} else {
			clockSample.Attributes["uncertainty_status"] = "local-bracket-only"
		}
		if err := client.SendBatch(ctx, []event.Event{health, clockSample}); err != nil {
			logger.Error("send health event", "error", err)
		}
	}
	emit()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			emit()
		}
	}
}
