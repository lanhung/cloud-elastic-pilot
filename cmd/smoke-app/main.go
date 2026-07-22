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
	"sync"
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

	cfg := hooke.ConfigFromEnv()
	var client *hooke.Client
	if envBool("HOOKE_SDK_DISABLED", false) {
		logger.Info("hooke SDK disabled; application events remain in the source journal")
	} else {
		var err error
		client, err = hooke.New(cfg)
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
	recorder := newApplicationEventRecorder(logger, client, cfg)
	mux := http.NewServeMux()
	registerHandlers(mux, recorder)

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
	recorder.emitOnce("warmup-finished", event.WarmupFinished, warmupFinishedAt, workAttributes)
	recorder.emitOnce("application-listening", event.ApplicationListening, listeningAt, map[string]any{"address": listener.Addr().String(), "port": 8080})
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server", "error", err)
			stop()
		}
	}()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
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

func registerHandlers(mux *http.ServeMux, recorder *applicationEventRecorder) {
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
		recorder.emitOnce("readiness-first-success", event.ReadinessProbeFirstSuccess, time.Now().UTC(), map[string]any{"path": r.URL.Path, "status": http.StatusOK})
	})
	handler := func(w http.ResponseWriter, r *http.Request) {
		started := time.Now().UTC()
		recorder.emitOnce("first-request", event.FirstRequestReceived, started, map[string]any{"method": r.Method, "path": r.URL.Path})
		workHandler(w, r)
		finished := time.Now().UTC()
		recorder.emitOnce("first-success", event.FirstSuccessfulResponse, finished, map[string]any{
			"method": r.Method, "path": r.URL.Path, "status": http.StatusOK,
			"duration_ms": float64(finished.Sub(started).Microseconds()) / 1000,
		})
	}
	mux.HandleFunc("/work", handler)
	mux.HandleFunc("/", handler)
}

type applicationEventRecorder struct {
	logger *slog.Logger
	client *hooke.Client
	cfg    hooke.Config
	once   sync.Map
}

func newApplicationEventRecorder(logger *slog.Logger, client *hooke.Client, cfg hooke.Config) *applicationEventRecorder {
	return &applicationEventRecorder{logger: logger, client: client, cfg: cfg}
}

func (r *applicationEventRecorder) emitOnce(key, eventType string, at time.Time, attributes map[string]any) {
	if _, loaded := r.once.LoadOrStore(key, struct{}{}); loaded {
		return
	}
	r.logger.Info("hooke application event",
		"hooke_event_type", eventType,
		"source_time_ns", at.UTC().UnixNano(),
		"hooke_cluster_id", r.cfg.ClusterID,
		"hooke_run_id", r.cfg.RunID,
		"pod_namespace", r.cfg.Namespace,
		"pod_name", r.cfg.PodName,
		"pod_uid", r.cfg.PodUID,
		"node_name", r.cfg.NodeName,
		"container_name", r.cfg.ContainerName,
		"workload_kind", r.cfg.WorkloadKind,
		"workload_name", r.cfg.WorkloadName,
		"hooke_attributes", attributes,
	)
	if r.client != nil {
		r.client.EmitOnceAsync(key, eventType, at, attributes)
	}
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
