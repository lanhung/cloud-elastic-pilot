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

	"github.com/hooke-repro/hooke-ack/internal/api"
	"github.com/hooke-repro/hooke-ack/internal/config"
	"github.com/hooke-repro/hooke-ack/internal/observability"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
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
	mux := http.NewServeMux()
	api.NewIngester(store, config.String("HOOKE_AUTH_TOKEN", ""), logger).Register(mux)
	observability.RegisterCommon(mux, func() bool { return true })
	server := &http.Server{Addr: config.String("HOOKE_HTTP_ADDR", ":8080"), Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second}
	go func() {
		logger.Info("ingester listening", "addr", server.Addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http server", "error", err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
}
