package kube

import (
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

type recordingEmitter struct {
	events []event.Event
}

func TestBaseForPodCapturesGOATScalerAttribution(t *testing.T) {
	collector := &Collector{cfg: Config{ClusterID: "cluster"}, state: NewState("")}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "pod-1",
			Namespace: "experiment",
			UID:       types.UID("pod-uid-1"),
			Annotations: map[string]string{
				goatTaskIDKey:        "task-1",
				goatProvisionNodeKey: "node-1",
			},
		},
	}

	got := collector.baseForPod(pod, "run-1")
	if got.Attributes["task_id"] != "task-1" {
		t.Fatalf("task_id = %#v", got.Attributes["task_id"])
	}
	if got.Attributes["provision_node_name"] != "node-1" {
		t.Fatalf("provision_node_name = %#v", got.Attributes["provision_node_name"])
	}
}

func TestEmitIfChangedPreservesBaseAttribution(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	base := event.New("cluster", "run", "", "test", time.Now())
	base.PodUID = "pod-uid"
	base.Attributes = map[string]any{"task_id": "task-1"}

	at := time.Unix(1_700_000_000, 123).UTC()
	collector.emitIfChanged(base, event.PodScheduled, "scheduled", at, map[string]any{"node_name": "node-1"}, false)

	if len(emitter.events) != 1 {
		t.Fatalf("got %d events, want 1", len(emitter.events))
	}
	attrs := emitter.events[0].Attributes
	if attrs["task_id"] != "task-1" || attrs["node_name"] != "node-1" {
		t.Fatalf("unexpected merged attributes: %#v", attrs)
	}
	if emitter.events[0].SourceTimeNS != at.UnixNano() || emitter.events[0].EventTimeNS != at.UnixNano() {
		t.Fatalf("source/event time did not preserve boundary: %#v", emitter.events[0])
	}
}

func TestIsCNIFailure(t *testing.T) {
	tests := []struct {
		message string
		want    bool
	}{
		{message: "failed to load /run/flannel/subnet.env", want: true},
		{message: "network plugin returned an error", want: true},
		{message: "failed to pull sandbox image", want: false},
	}
	for _, test := range tests {
		if got := isCNIFailure(test.message); got != test.want {
			t.Fatalf("isCNIFailure(%q) = %v, want %v", test.message, got, test.want)
		}
	}
}

func TestProvisionNodeEventCarriesOfficialTaskRelation(t *testing.T) {
	emitter := &recordingEmitter{}
	state := NewState("")
	state.SetNamespaceRun("experiment", "run-1")
	state.SetPodProvision("pod-uid-1", ProvisionMetadata{TaskID: "task-1", NodeName: "node-1"})
	collector := &Collector{cfg: Config{ClusterID: "cluster"}, state: state, emitter: emitter}
	kubernetesEvent := &corev1.Event{
		ObjectMeta: metav1.ObjectMeta{
			UID:               types.UID("event-uid-1"),
			Namespace:         "experiment",
			ResourceVersion:   "10",
			CreationTimestamp: metav1.NewTime(time.Now()),
		},
		InvolvedObject: corev1.ObjectReference{Kind: "Pod", Name: "pod-1", UID: types.UID("pod-uid-1")},
		Reason:         "ProvisionNode",
		Message:        "GOATScaler accepted the Pod",
		Count:          1,
	}

	collector.onKubernetesEvent(kubernetesEvent)

	if len(emitter.events) != 1 {
		t.Fatalf("got %d events, want 1", len(emitter.events))
	}
	got := emitter.events[0]
	if got.EventType != event.ACKProvisionRequested {
		t.Fatalf("event type = %q", got.EventType)
	}
	if got.Attributes["task_id"] != "task-1" || got.Attributes["provision_node_name"] != "node-1" {
		t.Fatalf("missing task relation: %#v", got.Attributes)
	}
	if got.Attributes["involved_object_uid"] != "pod-uid-1" {
		t.Fatalf("missing involved UID: %#v", got.Attributes)
	}
}

func TestNodeProvisionAttributesAreSelective(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{
			goatTaskIDKey: "task-1",
			"secret-like": "must-not-be-copied",
		}},
		Spec: corev1.NodeSpec{ProviderID: "aliyun:///i-1"},
	}
	got := nodeProvisionAttributes(node)
	if got["task_id"] != "task-1" || got["provider_id"] != "aliyun:///i-1" {
		t.Fatalf("unexpected attributes: %#v", got)
	}
	if _, copied := got["secret-like"]; copied {
		t.Fatalf("unexpected full label copy: %#v", got)
	}
}

func (e *recordingEmitter) Emit(item event.Event) error {
	e.events = append(e.events, item)
	return nil
}

func TestEmitIfChangedAssignsUniqueEventIDs(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	base := event.New("cluster", "run", "", "test", time.Now())
	base.PodUID = "pod-uid"

	collector.emitIfChanged(base, event.PodReady, "ready", time.Now(), nil, false)
	collector.emitIfChanged(base, event.ReadinessProbeFirstSuccess, "ready", time.Now(), nil, true)

	if len(emitter.events) != 2 {
		t.Fatalf("got %d events, want 2", len(emitter.events))
	}
	if emitter.events[0].EventID == "" || emitter.events[1].EventID == "" {
		t.Fatal("expected non-empty event IDs")
	}
	if emitter.events[0].EventID == emitter.events[1].EventID {
		t.Fatalf("distinct event types reused event ID %q", emitter.events[0].EventID)
	}
}

func TestEmitIfChangedFallsBackForNonPositiveTimestamp(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	base := event.New("cluster", "run", "", "test", time.Now())
	base.ClockType = event.ClockAPIServer

	collector.emitIfChanged(base, event.NodeNotReady, "not-ready", time.Time{}, nil, false)

	if len(emitter.events) != 1 {
		t.Fatalf("got %d events, want 1", len(emitter.events))
	}
	got := emitter.events[0]
	if got.EventTimeNS <= 0 {
		t.Fatalf("event time = %d, want positive fallback", got.EventTimeNS)
	}
	if !got.Approximate {
		t.Fatal("fallback event must be approximate")
	}
	if got.ClockType != event.ClockRealtime {
		t.Fatalf("clock type = %q, want %q", got.ClockType, event.ClockRealtime)
	}
	if got.Attributes["event_time_fallback"] != "observed_time" {
		t.Fatalf("missing fallback evidence: %#v", got.Attributes)
	}
	if err := got.Validate(); err != nil {
		t.Fatalf("fallback event is invalid: %v", err)
	}
}

func TestPodStatusContainerBoundaryIsApproximate(t *testing.T) {
	emitter := &recordingEmitter{}
	state := NewState("")
	state.SetNamespaceRun("experiment", "run-1")
	collector := &Collector{
		cfg:     Config{ClusterID: "cluster"},
		state:   state,
		emitter: emitter,
	}
	at := metav1.NewTime(time.Unix(1_800_000_000, 0).UTC())
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:              "pod-1",
			Namespace:         "experiment",
			UID:               types.UID("pod-uid-1"),
			CreationTimestamp: at,
		},
		Status: corev1.PodStatus{ContainerStatuses: []corev1.ContainerStatus{{
			Name:        "app",
			ContainerID: "containerd://container-1",
			State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{
				StartedAt: at,
			}},
		}}},
	}

	collector.onPod(pod, false)

	for _, item := range emitter.events {
		if item.EventType != event.ContainerStarted {
			continue
		}
		if !item.Approximate {
			t.Fatal("PodStatus container boundary must be approximate")
		}
		if item.Attributes["precision"] != "pod-status-second-resolution" {
			t.Fatalf("precision = %#v", item.Attributes["precision"])
		}
		return
	}
	t.Fatal("CONTAINER_STARTED event not emitted")
}
