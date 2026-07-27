package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/buildinfo"
	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := stageConfigFromEnv()
	if err != nil {
		logger.Error("configuration", "error", err)
		os.Exit(2)
	}
	hookeConfig := hooke.ConfigFromEnv()
	var sdkClient *hooke.Client
	if !boolEnv("HOOKE_SDK_DISABLED", true) {
		sdkClient, err = hooke.New(hookeConfig)
		if err != nil {
			logger.Error("hooke SDK", "error", err)
			os.Exit(2)
		}
	}
	recorder := newApplicationEventRecorder(logger, sdkClient, hookeConfig)
	defer recorder.Close()

	common := map[string]any{
		"stage_name":                  cfg.StageName,
		"variant":                     cfg.Variant,
		"declared_predecessors":       cfg.Predecessors,
		"true_dependency_annotation":  cfg.DependencyProof,
		"configured_work_duration_ns": cfg.WorkDuration.Nanoseconds(),
	}
	startedAt := time.Now().UTC()
	recorder.EmitOnce("useful-work-started", event.UsefulWorkStarted, startedAt, common)
	logger.Info("E06 stage started",
		"stage", cfg.StageName,
		"variant", cfg.Variant,
		"duration", cfg.WorkDuration,
		"version", buildinfo.Version,
		"commit", buildinfo.Commit,
		"build_date", buildinfo.Date,
	)

	timer := time.NewTimer(cfg.WorkDuration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		logger.Error("E06 stage interrupted", "stage", cfg.StageName, "error", ctx.Err())
		os.Exit(1)
	case <-timer.C:
	}
	finishedAt := time.Now().UTC()
	finished := make(map[string]any, len(common)+1)
	for key, value := range common {
		finished[key] = value
	}
	finished["observed_work_duration_ns"] = finishedAt.Sub(startedAt).Nanoseconds()
	recorder.EmitOnce("useful-work-finished", event.UsefulWorkFinished, finishedAt, finished)
	logger.Info("E06 stage completed",
		"stage", cfg.StageName,
		"variant", cfg.Variant,
		"duration", finishedAt.Sub(startedAt),
	)
}
