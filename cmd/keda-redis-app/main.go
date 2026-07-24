package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/hooke-repro/hooke-ack/internal/buildinfo"
	"github.com/hooke-repro/hooke-ack/internal/redisresp"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := configFromEnv()
	if err != nil {
		logger.Error("E04 configuration", "error", err)
		os.Exit(2)
	}
	sdkConfig := hooke.ConfigFromEnv()
	if sdkConfig.ClusterID == "" || sdkConfig.RunID == "" || sdkConfig.Namespace == "" ||
		sdkConfig.PodName == "" || sdkConfig.PodUID == "" || sdkConfig.NodeName == "" ||
		sdkConfig.ContainerName == "" || sdkConfig.WorkloadKind == "" || sdkConfig.WorkloadName == "" {
		logger.Error("Hooke correlation configuration is incomplete")
		os.Exit(2)
	}
	sdkConfig.SourceComponent = "e04-redis-" + cfg.Mode
	var client *hooke.Client
	if !envBool("HOOKE_SDK_DISABLED", true) {
		client, err = hooke.New(sdkConfig)
		if err != nil {
			logger.Error("Hooke SDK", "error", err)
			os.Exit(2)
		}
	}
	recorder := newApplicationEventRecorder(logger, client, sdkConfig)
	defer recorder.Close()
	queue, err := redisresp.New(cfg.RedisAddress, cfg.RedisPassword)
	if err != nil {
		logger.Error("Redis configuration", "error", err)
		os.Exit(2)
	}
	logger.Info("starting E04 Redis workload",
		"mode", cfg.Mode,
		"redis_address", cfg.RedisAddress,
		"queue_key", cfg.QueueKey,
		"completion_key", cfg.CompletionKey,
		"version", buildinfo.Version,
		"commit", buildinfo.Commit,
		"build_date", buildinfo.Date,
	)

	switch cfg.Mode {
	case "producer":
		err = runProducer(ctx, cfg, queue, recorder, logger, sdkConfig.RunID)
	case "worker":
		err = runWorker(ctx, cfg, queue, recorder, logger)
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("E04 Redis workload failed", "mode", cfg.Mode, "error", err)
		os.Exit(1)
	}
}
