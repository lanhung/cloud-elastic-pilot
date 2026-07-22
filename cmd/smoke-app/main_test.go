package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

func TestApplicationEventRecorderWritesExactSourceEventOnce(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	cfg := hooke.Config{
		ClusterID: "cluster-a", RunID: "run-a", Namespace: "ns", PodName: "pod",
		PodUID: "pod-uid", NodeName: "node-a", ContainerName: "app",
		WorkloadKind: "Deployment", WorkloadName: "workload",
	}
	recorder := newApplicationEventRecorder(logger, nil, cfg)
	at := time.Date(2026, 7, 22, 3, 34, 46, 899967158, time.UTC)
	recorder.emitOnce("ready", event.ReadinessProbeFirstSuccess, at, map[string]any{"status": 200})
	recorder.emitOnce("ready", event.ReadinessProbeFirstSuccess, at.Add(time.Second), map[string]any{"status": 200})

	scanner := bufio.NewScanner(&output)
	if !scanner.Scan() {
		t.Fatal("no application event log written")
	}
	var record struct {
		EventType    string         `json:"hooke_event_type"`
		SourceTimeNS int64          `json:"source_time_ns"`
		PodUID       string         `json:"pod_uid"`
		RunID        string         `json:"hooke_run_id"`
		Attributes   map[string]any `json:"hooke_attributes"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
		t.Fatalf("decode event log: %v", err)
	}
	if scanner.Scan() {
		t.Fatalf("once key emitted a second record: %s", scanner.Text())
	}
	if record.EventType != event.ReadinessProbeFirstSuccess {
		t.Fatalf("event type = %#v", record.EventType)
	}
	if got := record.SourceTimeNS; got != at.UnixNano() {
		t.Fatalf("source_time_ns = %d, want %d", got, at.UnixNano())
	}
	if record.PodUID != "pod-uid" || record.RunID != "run-a" {
		t.Fatalf("missing correlation fields: %#v", record)
	}
	if record.Attributes["status"] != float64(200) {
		t.Fatalf("attributes = %#v", record.Attributes)
	}
}
