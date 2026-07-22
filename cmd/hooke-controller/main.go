package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/config"
	"github.com/hooke-repro/hooke-ack/internal/kube"
	"github.com/hooke-repro/hooke-ack/internal/observability"
	"github.com/hooke-repro/hooke-ack/internal/transport"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	clusterID, err := config.Required("HOOKE_CLUSTER_ID")
	if err != nil {
		logger.Error("configuration", "error", err)
		os.Exit(2)
	}
	client := transport.NewClient(config.String("HOOKE_INGESTER_URL", "http://hooke-ingester.hooke-system.svc:8080"), config.String("HOOKE_AUTH_TOKEN", ""))
	batcher := transport.NewBatcher(client, config.Int("HOOKE_EVENT_QUEUE_SIZE", 8192), config.Int("HOOKE_EVENT_BATCH_SIZE", 100), config.Duration("HOOKE_EVENT_FLUSH_INTERVAL", 500*time.Millisecond), logger)
	batcher.Start(ctx)
	defer batcher.Close()
	collector, err := kube.NewCollector(kube.Config{ClusterID: clusterID, DefaultRunID: config.String("HOOKE_ACTIVE_RUN_ID", ""), HookeNamespace: config.String("HOOKE_NAMESPACE", "hooke-system"), WatchActiveRunConfigMap: config.Bool("HOOKE_WATCH_ACTIVE_RUN_CONFIGMAP", true), CaptureUnlabeled: config.Bool("HOOKE_CAPTURE_UNLABELED", false), Kubeconfig: config.String("KUBECONFIG", "")}, batcher, logger)
	if err != nil {
		logger.Error("create collector", "error", err)
		os.Exit(1)
	}
	mux := http.NewServeMux()
	observability.RegisterCommon(mux, func() bool { return true })
	server := &http.Server{Addr: config.String("HOOKE_METRICS_ADDR", ":8081"), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("metrics server", "error", err)
		}
	}()
	if err := collector.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("collector stopped", "error", err)
		os.Exit(1)
	}
}
