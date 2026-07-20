package correlate

import (
	"testing"

	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

func TestBuildTraceMergesPodAndContainerScopedEvents(t *testing.T) {
	makeRow := func(typ string, ts int64, pod, node, container string) mysqlstore.EventRow {
		return mysqlstore.EventRow{Event: event.Event{
			RunID:         "r",
			PodUID:        pod,
			PodName:       "p",
			NodeName:      node,
			ContainerName: container,
			EventType:     typ,
			EventTimeNS:   ts,
			Attributes:    map[string]any{},
		}}
	}
	rows := []mysqlstore.EventRow{
		makeRow(event.PodCreated, 1_000_000_000, "p1", "", ""),
		makeRow(event.PodUnschedulable, 2_000_000_000, "p1", "", ""),
		makeRow(event.PodScheduled, 4_000_000_000, "p1", "n1", ""),
		makeRow(event.NodeReady, 10_000_000_000, "", "n1", ""),
		makeRow(event.ContainerStarted, 12_000_000_000, "p1", "n1", "app"),
		makeRow(event.PodReady, 13_000_000_000, "p1", "n1", ""),
	}
	traces := Builder{}.Build(rows)
	if len(traces) != 1 {
		t.Fatalf("got %d", len(traces))
	}
	if traces[0].ContainerName != "app" {
		t.Fatalf("container name %q", traces[0].ContainerName)
	}
	if traces[0].NodeLatencyMS != 8000 {
		t.Fatalf("node latency %v", traces[0].NodeLatencyMS)
	}
	if traces[0].PodLatencyMS != 8000 {
		t.Fatalf("pod latency %v", traces[0].PodLatencyMS)
	}
	if traces[0].AppLatencyMS != 1000 {
		t.Fatalf("app latency %v", traces[0].AppLatencyMS)
	}
	if !traces[0].Complete {
		t.Fatal("expected complete trace")
	}
}

func TestBuildTraceUsesMatchingGOATScalerTask(t *testing.T) {
	rows := []mysqlstore.EventRow{
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.PodUnschedulable, EventTimeNS: 1_000_000_000, Attributes: map[string]any{}}},
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.ACKProvisionTaskUpdated, EventTimeNS: 2_000_000_000, Attributes: map[string]any{"task_id": "task-1", "provision_node_name": "n1"}}},
		{Event: event.Event{RunID: "r", EventType: event.ACKProvisionTaskCreated, EventTimeNS: 3_000_000_000, NodeName: "n1", Attributes: map[string]any{"task_id": "task-1", "instance_id": "i-1", "pending_pod_uids": []any{"p1"}}}},
		{Event: event.Event{RunID: "r", EventType: event.NodeReady, EventTimeNS: 10_000_000_000, NodeName: "n1", Attributes: map[string]any{"task_id": "task-1", "provider_id": "aliyun:///i-1"}}},
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.PodScheduled, EventTimeNS: 11_000_000_000, NodeName: "n1", Attributes: map[string]any{"task_id": "task-1"}}},
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.ContainerStarted, EventTimeNS: 12_000_000_000, NodeName: "n1", ContainerName: "app", Attributes: map[string]any{"task_id": "task-1"}}},
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.PodReady, EventTimeNS: 13_000_000_000, NodeName: "n1", Attributes: map[string]any{"task_id": "task-1"}}},
	}

	traces := Builder{}.Build(rows)
	if len(traces) != 1 {
		t.Fatalf("got %d traces", len(traces))
	}
	got := traces[0]
	if got.NodeStartNS != 3_000_000_000 || got.NodeLatencyMS != 7000 {
		t.Fatalf("unexpected exact node interval: %#v", got)
	}
	if got.Quality["node_attribution_method"] != "task-id" || got.Quality["node_task_match"] != true {
		t.Fatalf("unexpected attribution quality: %#v", got.Quality)
	}
	if got.Quality["provider_id"] != "aliyun:///i-1" || got.Quality["instance_id"] != "i-1" {
		t.Fatalf("missing cloud identifiers: %#v", got.Quality)
	}
}

func TestBuildTraceDoesNotUseNodeNameFallbackWhenTaskIDIsKnown(t *testing.T) {
	rows := []mysqlstore.EventRow{
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.PodUnschedulable, EventTimeNS: 1_000_000_000, Attributes: map[string]any{}}},
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.ACKProvisionTaskUpdated, EventTimeNS: 2_000_000_000, Attributes: map[string]any{"task_id": "task-1"}}},
		{Event: event.Event{RunID: "r", EventType: event.ACKProvisionTaskCreated, EventTimeNS: 3_000_000_000, NodeName: "n1", Attributes: map[string]any{"task_id": "task-2"}}},
		{Event: event.Event{RunID: "r", PodUID: "p1", PodName: "p", EventType: event.PodScheduled, EventTimeNS: 4_000_000_000, NodeName: "n1", Attributes: map[string]any{}}},
	}

	traces := Builder{}.Build(rows)
	if len(traces) != 1 {
		t.Fatalf("got %d traces", len(traces))
	}
	got := traces[0]
	if got.NodeStartNS != 1_000_000_000 {
		t.Fatalf("mismatched node-name task replaced the Pod baseline: %#v", got)
	}
	if got.Quality["node_start_event"] != event.PodUnschedulable || got.Quality["node_approximate"] != true {
		t.Fatalf("mismatched task was marked exact: %#v", got.Quality)
	}
}
