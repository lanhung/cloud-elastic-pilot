package attribution

import (
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

func TestAnalyzeComparesTaskIDAndTimeWindow(t *testing.T) {
	events := []event.Event{
		{EventType: event.PodUnschedulable, EventTimeNS: 1, PodUID: "p1", PodName: "pod-1", Attributes: map[string]any{}},
		{EventType: event.PodUnschedulable, EventTimeNS: 2, PodUID: "p2", PodName: "pod-2", Attributes: map[string]any{}},
		{EventType: event.ACKProvisionTaskUpdated, EventTimeNS: 2, SourceComponent: "kubernetes-pod-watch", PodUID: "p1", Attributes: map[string]any{"task_id": "t1", "provision_node_name": "n1"}},
		{EventType: event.ACKProvisionTaskUpdated, EventTimeNS: 2, SourceComponent: "kubernetes-pod-watch", PodUID: "p2", Attributes: map[string]any{"task_id": "t2", "provision_node_name": "n2"}},
		{EventType: event.NodeReady, EventTimeNS: 3, SourceComponent: "kubernetes-node-watch", NodeName: "n2", Attributes: map[string]any{"task_id": "t2", "provider_id": "aliyun:///i-2"}},
		{EventType: event.NodeReady, EventTimeNS: 5, SourceComponent: "kubernetes-node-watch", NodeName: "n1", Attributes: map[string]any{"task_id": "t1", "provider_id": "aliyun:///i-1"}},
		{EventType: event.PodScheduled, EventTimeNS: 6, PodUID: "p1", NodeName: "n1", Attributes: map[string]any{"task_id": "t1"}},
		{EventType: event.PodScheduled, EventTimeNS: 6, PodUID: "p2", NodeName: "n2", Attributes: map[string]any{"task_id": "t2"}},
		{EventType: event.ECSInstanceRunning, EventTimeNS: 4, Attributes: map[string]any{"task_id": "t1", "instance_id": "i-1"}},
		{EventType: event.ECSInstanceRunning, EventTimeNS: 4, Attributes: map[string]any{"task_id": "t2", "instance_id": "i-2"}},
	}

	report := Analyze(events, time.Second)
	if report.GroundTruthPods != 2 || report.UniqueTasks != 2 {
		t.Fatalf("unexpected coverage counts: %#v", report)
	}
	if report.PodTaskIDCoverage != 1 || report.NodeTaskIDCoverage != 1 || report.ProviderIDCoverage != 1 || report.InstanceIDCoverage != 1 {
		t.Fatalf("unexpected coverage: %#v", report)
	}
	if got := report.Methods[MethodTaskID]; got.Precision != 1 || got.Recall != 1 || got.F1 != 1 {
		t.Fatalf("task-id result: %#v", got)
	}
	if got := report.Methods[MethodKubernetesNode]; got.Precision != 1 || got.Recall != 1 {
		t.Fatalf("kubernetes-node result: %#v", got)
	}
	if got := report.Methods[MethodTimeWindow]; got.Precision != .5 || got.Recall != .5 {
		t.Fatalf("time-window result: %#v", got)
	}
}

func TestAnalyzeReportsConflictingTaskIDs(t *testing.T) {
	report := Analyze([]event.Event{
		{SourceComponent: "kubernetes-pod-watch", PodUID: "p1", Attributes: map[string]any{"task_id": "t1"}},
		{SourceComponent: "kubernetes-pod-watch", PodUID: "p1", Attributes: map[string]any{"task_id": "t2"}},
	}, time.Minute)
	if report.TaskNodeConflictCount != 1 {
		t.Fatalf("conflicts = %#v", report.Conflicts)
	}
}

func TestAnalyzeDoesNotTreatACKPendingListAsPodAnnotationCoverage(t *testing.T) {
	report := Analyze([]event.Event{
		{EventType: event.PodUnschedulable, EventTimeNS: 1, PodUID: "p1", Attributes: map[string]any{}},
		{EventType: event.ACKProvisionTaskCreated, EventTimeNS: 2, SourceComponent: "ack-log-adapter", Attributes: map[string]any{"task_id": "t1", "pending_pod_uids": []any{"p1"}}},
	}, time.Minute)
	if report.GroundTruthPods != 0 || report.PodTaskIDCoverage != 0 {
		t.Fatalf("ACK log substituted for Pod annotation: %#v", report)
	}
}
