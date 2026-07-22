package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
	"github.com/prometheus/client_golang/prometheus"
)

var (
	eventsReceived = prometheus.NewCounterVec(prometheus.CounterOpts{Name: "hooke_ingester_events_received_total", Help: "Events received by result."}, []string{"result"})
	batchDuration  = prometheus.NewHistogram(prometheus.HistogramOpts{Name: "hooke_ingester_batch_insert_seconds", Help: "MySQL batch insert latency."})
)

func init() {
	prometheus.MustRegister(eventsReceived, batchDuration)
}

type Ingester struct {
	store  *mysqlstore.Store
	token  string
	logger *slog.Logger
}

func NewIngester(store *mysqlstore.Store, token string, logger *slog.Logger) *Ingester {
	return &Ingester{store: store, token: token, logger: logger}
}

func (i *Ingester) Register(mux *http.ServeMux) {
	mux.HandleFunc("/v1/events:batch", i.auth(i.handleEvents))
	mux.HandleFunc("/v1/runs", i.auth(i.handleRuns))
	mux.HandleFunc("/v1/runs/", i.auth(i.handleRunByID))
}

func (i *Ingester) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if i.token != "" && r.Header.Get("Authorization") != "Bearer "+i.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (i *Ingester) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, 8<<20))
	decoder.DisallowUnknownFields()
	var request struct {
		Events []event.Event `json:"events"`
	}
	if err := decoder.Decode(&request); err != nil {
		http.Error(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(request.Events) == 0 || len(request.Events) > 2000 {
		http.Error(w, "events count must be between 1 and 2000", http.StatusBadRequest)
		return
	}
	ingestTimeNS := time.Now().UTC().UnixNano()
	for idx := range request.Events {
		// Producer-supplied ingest timestamps are never trusted. One batch gets a
		// single ingress timestamp so intra-batch comparisons are deterministic.
		request.Events[idx].IngestTimeNS = ingestTimeNS
		request.Events[idx].Normalize()
		if err := request.Events[idx].Validate(); err != nil {
			eventsReceived.WithLabelValues("invalid").Inc()
			http.Error(w, "invalid event: "+err.Error(), http.StatusBadRequest)
			return
		}
	}
	start := time.Now()
	inserted, err := i.store.InsertEvents(r.Context(), request.Events)
	batchDuration.Observe(time.Since(start).Seconds())
	if err != nil {
		eventsReceived.WithLabelValues("error").Add(float64(len(request.Events)))
		i.logger.Error("insert events", "error", err)
		http.Error(w, "storage error", http.StatusInternalServerError)
		return
	}
	eventsReceived.WithLabelValues("accepted").Add(float64(len(request.Events)))
	writeJSON(w, http.StatusAccepted, map[string]any{"accepted": len(request.Events), "inserted": inserted, "duplicates": int64(len(request.Events)) - inserted})
}

func (i *Ingester) handleRuns(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var request struct {
		ClusterID  string         `json:"cluster_id"`
		Name       string         `json:"name"`
		SLOSeconds float64        `json:"slo_seconds"`
		Labels     map[string]any `json:"labels"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&request); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if request.ClusterID == "" || request.Name == "" {
		http.Error(w, "cluster_id and name are required", http.StatusBadRequest)
		return
	}
	run, err := i.store.CreateRun(r.Context(), mysqlstore.Run{ClusterID: request.ClusterID, Name: request.Name, SLOSeconds: request.SLOSeconds, Labels: request.Labels})
	if err != nil {
		i.logger.Error("create run", "error", err)
		http.Error(w, "storage error", http.StatusInternalServerError)
		return
	}
	e := event.New(run.ClusterID, run.RunID, event.ExperimentStarted, "hooke-ingester", run.StartedAt)
	e.Attributes = map[string]any{"name": run.Name, "slo_seconds": run.SLOSeconds}
	_, _ = i.store.InsertEvents(context.Background(), []event.Event{e})
	writeJSON(w, http.StatusCreated, run)
}

func (i *Ingester) handleRunByID(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/v1/runs/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		http.NotFound(w, r)
		return
	}
	runID := parts[0]
	if len(parts) == 2 && parts[1] == "stop" && r.Method == http.MethodPost {
		run, err := i.store.GetRun(r.Context(), runID)
		if err != nil {
			http.Error(w, "run not found", http.StatusNotFound)
			return
		}
		if err := i.store.StopRun(r.Context(), runID); err != nil {
			if errors.Is(err, context.Canceled) {
				http.Error(w, err.Error(), http.StatusRequestTimeout)
			} else {
				http.Error(w, err.Error(), http.StatusConflict)
			}
			return
		}
		e := event.New(run.ClusterID, run.RunID, event.ExperimentStopped, "hooke-ingester", time.Now())
		_, _ = i.store.InsertEvents(context.Background(), []event.Event{e})
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if len(parts) == 1 && r.Method == http.MethodGet {
		run, err := i.store.GetRun(r.Context(), runID)
		if err != nil {
			http.Error(w, "run not found", http.StatusNotFound)
			return
		}
		writeJSON(w, http.StatusOK, run)
		return
	}
	http.NotFound(w, r)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
