package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	mux := http.NewServeMux()
	if envBool("HOOKE_SDK_DISABLED", false) {
		registerPlainHandlers(mux)
		logger.Info("hooke SDK disabled for local-ingester smoke mode")
	} else {
		client, err := hooke.New(hooke.ConfigFromEnv())
		if err != nil {
			logger.Error("hooke SDK", "error", err)
			os.Exit(2)
		}
		_ = client.Emit(ctx, event.ApplicationListening, map[string]any{"port": 8080})
		registerInstrumentedHandlers(mux, client)
	}

	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server", "error", err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
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
