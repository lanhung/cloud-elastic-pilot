package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/buildinfo"
	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

var startupDigest [sha256.Size]byte

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var client *hooke.Client
	if envBool("HOOKE_SDK_DISABLED", false) {
		logger.Info("hooke SDK disabled for local-ingester smoke mode")
	} else {
		var err error
		client, err = hooke.New(hooke.ConfigFromEnv())
		if err != nil {
			logger.Error("hooke SDK", "error", err)
			os.Exit(2)
		}
	}

	workMiB, err := envNonNegativeInt("HOOKE_STARTUP_WORK_MIB", 0)
	if err != nil {
		logger.Error("startup work configuration", "error", err)
		os.Exit(2)
	}
	workStarted := time.Now().UTC()
	if err := runStartupWork(ctx, workMiB); err != nil {
		logger.Error("startup work", "error", err)
		os.Exit(1)
	}
	workDuration := time.Since(workStarted)
	warmupFinishedAt := time.Now().UTC()
	workAttributes := map[string]any{
		"kind": "sha256-stream", "work_mib": workMiB,
		"duration_ms": float64(workDuration.Microseconds()) / 1000,
		"digest":      fmt.Sprintf("%x", startupDigest[:]),
	}
	mux := http.NewServeMux()
	if client == nil {
		registerPlainHandlers(mux)
	} else {
		registerInstrumentedHandlers(mux, client)
	}

	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		logger.Error("listen", "error", err)
		os.Exit(1)
	}
	listeningAt := time.Now().UTC()
	logger.Info("application listening", "address", listener.Addr().String(), "startup_work_mib", workMiB, "startup_work_duration", workDuration,
		"version", buildinfo.Version, "commit", buildinfo.Commit, "build_date", buildinfo.Date)
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server", "error", err)
			stop()
		}
	}()
	if client != nil {
		go emitApplicationEvent(ctx, logger, client, event.WarmupFinished, warmupFinishedAt, workAttributes)
		go emitApplicationEvent(ctx, logger, client, event.ApplicationListening, listeningAt, map[string]any{"address": listener.Addr().String(), "port": 8080})
	}
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
}

func emitApplicationEvent(ctx context.Context, logger *slog.Logger, client *hooke.Client, eventType string, at time.Time, attributes map[string]any) {
	emitCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := client.EmitAt(emitCtx, eventType, at, attributes); err != nil {
		logger.Error("emit application event", "event_type", eventType, "error", err)
	}
}

func runStartupWork(ctx context.Context, workMiB int) error {
	block := make([]byte, 1<<20)
	for index := 0; index < workMiB; index++ {
		if index%64 == 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
			}
		}
		copy(block, startupDigest[:])
		block[len(block)-1] = byte(index)
		startupDigest = sha256.Sum256(block)
	}
	return nil
}

func registerPlainHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/work", workHandler)
	mux.HandleFunc("/", workHandler)
}

func registerInstrumentedHandlers(mux *http.ServeMux, client *hooke.Client) {
	mux.Handle("/readyz", client.ReadinessHandler(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})))
	mux.Handle("/work", client.FirstRequestMiddleware(http.HandlerFunc(workHandler)))
	mux.Handle("/", client.FirstRequestMiddleware(http.HandlerFunc(workHandler)))
}

func workHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "time": time.Now().UTC()})
}

func envBool(key string, fallback bool) bool {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	value, err := strconv.ParseBool(raw)
	if err != nil {
		return fallback
	}
	return value
}

func envNonNegativeInt(key string, fallback int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return 0, fmt.Errorf("%s must be a non-negative integer", key)
	}
	return value, nil
}
