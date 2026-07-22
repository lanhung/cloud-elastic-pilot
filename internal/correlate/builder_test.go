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

func TestBuildTracePrefersExactFourLayerEventsAndMatchesImageDigest(t *testing.T) {
	digest := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	imageRef := "registry.example.com/hooke/smoke@" + digest
	row := func(id, typ string, ts int64) mysqlstore.EventRow {
		return mysqlstore.EventRow{Event: event.Event{
			EventID: id, RunID: "r", PodUID: "p1", PodName: "p", NodeName: "n1",
			EventType: typ, EventTimeNS: ts, Attributes: map[string]any{},
		}}
	}
	rows := []mysqlstore.EventRow{
		row("pod-created", event.PodCreated, 1_000_000_000),
		row("pod-scheduled", event.PodScheduled, 2_000_000_000),
		{Event: event.Event{EventID: "approx-pull-start", RunID: "r", PodUID: "p1", EventType: event.ImagePullStart, EventTimeNS: 3_000_000_000, ImageRef: imageRef, Approximate: true, Attributes: map[string]any{}}},
		{Event: event.Event{EventID: "approx-pull-end", RunID: "r", PodUID: "p1", EventType: event.ImagePullEnd, EventTimeNS: 9_000_000_000, ImageRef: imageRef, Approximate: true, Attributes: map[string]any{}}},
		{Event: event.Event{EventID: "exact-pull-start", RunID: "r", PodUID: "p1", EventType: event.ImagePullStart, EventTimeNS: 4_000_000_000, ImageDigest: "containerd://" + digest, Attributes: map[string]any{}}},
		{Event: event.Event{EventID: "exact-pull-end", RunID: "r", PodUID: "p1", EventType: event.ImagePullEnd, EventTimeNS: 6_000_000_000, ImageDigest: digest, Attributes: map[string]any{}}},
		{Event: event.Event{EventID: "exact-unpack-start", RunID: "r", PodUID: "p1", EventType: event.ImageUnpackStart, EventTimeNS: 6_000_000_000, ImageDigest: digest, Attributes: map[string]any{}}},
		{Event: event.Event{EventID: "exact-unpack-end", RunID: "r", PodUID: "p1", EventType: event.ImageUnpackEnd, EventTimeNS: 8_000_000_000, ImageDigest: digest, Attributes: map[string]any{}}},
		row("sync-pod", event.SyncPodStart, 8_500_000_000),
		row("sandbox-start", event.PodSandboxStart, 8_600_000_000),
		row("cni-start", event.CNISetupStart, 8_700_000_000),
		row("cni-end", event.CNISetupEnd, 9_000_000_000),
		row("sandbox-end", event.PodSandboxEnd, 9_100_000_000),
		{Event: event.Event{EventID: "container-started", RunID: "r", PodUID: "p1", PodName: "p", NodeName: "n1", ContainerName: "app", EventType: event.ContainerStarted, EventTimeNS: 10_000_000_000, ImageRef: imageRef, ImageDigest: "containerd://" + digest, Attributes: map[string]any{}}},
		row("pod-ready", event.PodReady, 12_000_000_000),
		row("exact-ready", event.ReadinessProbeFirstSuccess, 13_000_000_000),
	}

	traces := Builder{}.Build(rows)
	if len(traces) != 1 {
		t.Fatalf("got %d traces", len(traces))
	}
	got := traces[0]
	if got.ImagePullStartNS != 4_000_000_000 || got.ImageUnpackEndNS != 8_000_000_000 {
		t.Fatalf("exact image interval not selected: %#v", got)
	}
	if got.ReadinessSuccessNS != 13_000_000_000 {
		t.Fatalf("exact readiness did not replace PodReady fallback: %d", got.ReadinessSuccessNS)
	}
	for _, key := range []string{"image_approximate", "pod_approximate", "app_approximate", "sandbox_approximate", "cni_approximate"} {
		if approximate, _ := got.Quality[key].(bool); approximate {
			t.Fatalf("%s unexpectedly approximate: %#v", key, got.Quality)
		}
	}
	if got.Quality["image_start_event_id"] != "exact-pull-start" || got.Quality["image_end_event_id"] != "exact-unpack-end" {
		t.Fatalf("image derivation IDs are not exact: %#v", got.Quality)
	}
	if got.Quality["app_end_event_id"] != "exact-ready" || got.ExactCoverage != 1 || !got.Complete {
		t.Fatalf("unexpected exact trace quality: %#v", got)
	}
	if len(got.AllSamples()) != 6 {
		t.Fatalf("got %d samples, want 3 primary + unpack/sandbox/CNI", len(got.AllSamples()))
	}
}
