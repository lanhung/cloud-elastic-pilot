package main

import (
	"context"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

type applicationEventRecorder struct {
	logger *slog.Logger
	client *hooke.Client
	cfg    hooke.Config
	once   sync.Map
	wg     sync.WaitGroup
}

func newApplicationEventRecorder(logger *slog.Logger, client *hooke.Client, cfg hooke.Config) *applicationEventRecorder {
	return &applicationEventRecorder{logger: logger, client: client, cfg: cfg}
}

func (r *applicationEventRecorder) EmitOnce(key, eventType string, at time.Time, attributes map[string]any) {
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
		"workload_uid", r.cfg.WorkloadUID,
		"hooke_attributes", attributes,
	)
	if r.client == nil {
		return
	}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := r.client.EmitAt(ctx, eventType, at, attributes); err != nil {
			r.logger.Error("send Hooke application event", "event_type", eventType, "error", err)
		}
	}()
}

func (r *applicationEventRecorder) Close() {
	r.wg.Wait()
}

func boolEnv(key string, fallback bool) bool {
	raw := env(key, strconv.FormatBool(fallback))
	value, err := strconv.ParseBool(raw)
	if err != nil {
		return fallback
	}
	return value
}
