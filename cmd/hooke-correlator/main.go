package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/config"
	"github.com/hooke-repro/hooke-ack/internal/correlate"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

func main() {
	runID := flag.String("run-id", "", "experiment run ID")
	once := flag.Bool("once", true, "run once and exit")
	interval := flag.Duration("interval", 30*time.Second, "continuous calculation interval")
	flag.Parse()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if *runID == "" {
		logger.Error("--run-id is required")
		os.Exit(2)
	}
	dsn, err := config.Required("HOOKE_MYSQL_DSN")
	if err != nil {
		logger.Error("configuration", "error", err)
		os.Exit(2)
	}
	store, err := mysqlstore.Open(ctx, dsn)
	if err != nil {
		logger.Error("open mysql", "error", err)
		os.Exit(1)
	}
	defer store.Close()
	run, err := store.GetRun(ctx, *runID)
	if err != nil {
		logger.Error("get run", "error", err)
		os.Exit(1)
	}
	execute := func() error {
		summary, err := correlate.Execute(ctx, store, *runID, run.SLOSeconds)
		if err != nil {
			return err
		}
		payload, _ := json.MarshalIndent(summary, "", "  ")
		fmt.Println(string(payload))
		return nil
	}
	if *once {
		if err := execute(); err != nil {
			logger.Error("calculate", "error", err)
			os.Exit(1)
		}
		return
	}
	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for {
		if err := execute(); err != nil {
			logger.Error("calculate", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
