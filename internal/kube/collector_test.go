package kube

import (
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
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

func TestExplicitDefaultRunIgnoresSharedActiveRunConfigMap(t *testing.T) {
	collector := &Collector{
		cfg:   Config{DefaultRunID: "fixed-run"},
		state: NewState("fixed-run"),
	}
	for _, runID := range []string{"other-run", ""} {
		collector.onConfigMap(&corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: "hooke-active-run", Namespace: "hooke-system"},
			Data:       map[string]string{"run_id": runID},
		})
		if got := collector.state.RunID("", nil); got != "fixed-run" {
			t.Fatalf("cluster-scoped run = %q after ConfigMap value %q, want fixed-run", got, runID)
		}
	}
}

func TestDisabledActiveRunWatchIgnoresSharedConfigMap(t *testing.T) {
	collector := &Collector{
		cfg:   Config{WatchActiveRunConfigMap: false},
		state: NewState(""),
	}
	collector.onConfigMap(&corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "hooke-active-run", Namespace: "hooke-system"},
		Data:       map[string]string{"run_id": "other-run"},
	})
	if got := collector.state.RunID("", nil); got != "" {
		t.Fatalf("cluster-scoped run = %q with ConfigMap watch disabled, want empty", got)
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

func TestEmitIfChangedSeparatesWorkloadUIDs(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	for _, uid := range []string{"workload-a", "workload-b"} {
		base := event.New("cluster", "run", "", "test", time.Now())
		base.Namespace = "experiment"
		base.WorkloadUID = uid
		collector.emitIfChanged(base, event.HPADesiredReplicasChanged, "0/1", time.Now(), nil, true)
	}
	if len(emitter.events) != 2 {
		t.Fatalf("got %d events, want one event for each workload", len(emitter.events))
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

func TestKEDAActiveAndInactiveTransitions(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	base := event.New("cluster", "run", "", "kubernetes-dynamic-watch", time.Now())
	base.Namespace = "experiment"
	base.WorkloadKind = "ScaledObject"
	base.WorkloadName = "worker"
	base.WorkloadUID = "scaledobject-uid"

	createdAt := time.Date(2026, 7, 24, 1, 0, 0, 0, time.UTC)
	activeAt := createdAt.Add(time.Minute)
	inactiveAt := activeAt.Add(time.Minute)
	object := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "keda.sh/v1alpha1",
		"kind":       "ScaledObject",
		"metadata": map[string]any{
			"name":              "worker",
			"namespace":         "experiment",
			"uid":               "scaledobject-uid",
			"creationTimestamp": createdAt.Format(time.RFC3339),
		},
		"spec": map[string]any{"cooldownPeriod": int64(60)},
	}}
	object.SetUID(types.UID("scaledobject-uid"))
	object.SetCreationTimestamp(metav1.NewTime(createdAt))
	object.Object["status"] = map[string]any{"conditions": []any{map[string]any{
		"type": "Active", "status": "True",
		"lastTransitionTime": activeAt.Format(time.RFC3339Nano),
	}}}
	collector.emitKEDA(base, object)

	object.Object["status"] = map[string]any{"conditions": []any{map[string]any{
		"type": "Active", "status": "False",
		"lastTransitionTime": inactiveAt.Format(time.RFC3339Nano),
	}}}
	collector.emitKEDA(base, object)

	var active, inactive *event.Event
	for index := range emitter.events {
		switch emitter.events[index].EventType {
		case event.KEDAScaledObjectActive:
			active = &emitter.events[index]
		case event.KEDAScaledObjectInactive:
			inactive = &emitter.events[index]
		}
	}
	if active == nil || inactive == nil {
		t.Fatalf("missing KEDA transition events: %#v", emitter.events)
	}
	if active.EventTimeNS != activeAt.UnixNano() || inactive.EventTimeNS != inactiveAt.UnixNano() {
		t.Fatalf("condition transition timestamps were not preserved: active=%d inactive=%d", active.EventTimeNS, inactive.EventTimeNS)
	}
	if active.Approximate || inactive.Approximate {
		t.Fatal("valid ScaledObject transition timestamps must be exact")
	}
}

func TestKEDAInactiveRepeatsAfterActiveWithoutTransitionTime(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	base := event.New("cluster", "run", "", "kubernetes-dynamic-watch", time.Now())
	base.Namespace = "experiment"
	base.WorkloadKind = "ScaledObject"
	base.WorkloadName = "worker"
	base.WorkloadUID = "scaledobject-uid"

	object := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "keda.sh/v1alpha1",
		"kind":       "ScaledObject",
		"metadata": map[string]any{
			"name":      "worker",
			"namespace": "experiment",
			"uid":       "scaledobject-uid",
		},
	}}
	object.SetUID(types.UID("scaledobject-uid"))

	emitStatus := func(resourceVersion, status string) {
		object.SetResourceVersion(resourceVersion)
		object.Object["status"] = map[string]any{"conditions": []any{map[string]any{
			"type": "Active", "status": status,
		}}}
		collector.emitKEDA(base, object)
	}
	emitStatus("1", "False")
	emitStatus("2", "True")
	emitStatus("3", "False")

	var transitions []string
	for _, item := range emitter.events {
		switch item.EventType {
		case event.KEDAScaledObjectActive, event.KEDAScaledObjectInactive:
			transitions = append(transitions, item.EventType)
			if !item.Approximate {
				t.Fatalf("transition without lastTransitionTime must be approximate: %#v", item)
			}
		}
	}
	if len(transitions) != 3 ||
		transitions[0] != event.KEDAScaledObjectInactive ||
		transitions[1] != event.KEDAScaledObjectActive ||
		transitions[2] != event.KEDAScaledObjectInactive {
		t.Fatalf("unexpected KEDA transitions: %#v", transitions)
	}
}

func TestKEDAHPAEmitsExternalMetricSample(t *testing.T) {
	emitter := &recordingEmitter{}
	state := NewState("")
	state.SetNamespaceRun("experiment", "run-1")
	collector := &Collector{
		cfg:     Config{ClusterID: "cluster"},
		state:   state,
		emitter: emitter,
	}
	average := resource.MustParse("3")
	minimum := int32(1)
	hpa := &autoscalingv2.HorizontalPodAutoscaler{
		ObjectMeta: metav1.ObjectMeta{
			Name:            "keda-hpa-worker",
			Namespace:       "experiment",
			UID:             types.UID("hpa-uid"),
			ResourceVersion: "42",
			Labels: map[string]string{
				kedaScaledObjectLabel: "worker",
			},
		},
		Spec: autoscalingv2.HorizontalPodAutoscalerSpec{
			ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{Kind: "Deployment", Name: "worker"},
			MinReplicas:    &minimum,
			MaxReplicas:    4,
		},
		Status: autoscalingv2.HorizontalPodAutoscalerStatus{
			CurrentReplicas: 1,
			DesiredReplicas: 2,
			CurrentMetrics: []autoscalingv2.MetricStatus{{
				Type: autoscalingv2.ExternalMetricSourceType,
				External: &autoscalingv2.ExternalMetricStatus{
					Metric: autoscalingv2.MetricIdentifier{Name: "s0-redis-worker"},
					Current: autoscalingv2.MetricValueStatus{
						AverageValue: &average,
					},
				},
			}},
		},
	}

	collector.onHPA(hpa)

	for _, item := range emitter.events {
		if item.EventType != event.KEDAScalerSample {
			continue
		}
		if item.Attributes["scaled_object"] != "worker" ||
			item.Attributes["metric_name"] != "s0-redis-worker" ||
			item.Attributes["current_average_value"] != "3" {
			t.Fatalf("unexpected scaler sample: %#v", item.Attributes)
		}
		if !item.Approximate || item.Attributes["precision"] != "hpa-status-observation" {
			t.Fatalf("HPA sample precision is not explicit: %#v", item)
		}
		return
	}
	t.Fatalf("KEDA scaler sample not emitted: %#v", emitter.events)
}

func TestKEDADeploymentScaleToZero(t *testing.T) {
	emitter := &recordingEmitter{}
	state := NewState("")
	state.SetNamespaceRun("experiment", "run-1")
	collector := &Collector{
		cfg:     Config{ClusterID: "cluster"},
		state:   state,
		emitter: emitter,
	}
	zero := int32(0)
	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:            "worker",
			Namespace:       "experiment",
			UID:             types.UID("deployment-uid"),
			ResourceVersion: "7",
			Generation:      3,
			Annotations: map[string]string{
				hookeKEDAObjectKey: "worker",
			},
		},
		Spec: appsv1.DeploymentSpec{Replicas: &zero},
	}

	collector.onDeployment(deployment)
	for _, item := range emitter.events {
		if item.EventType == event.KEDAScaleToZero {
			t.Fatal("initial replicas=0 observation must not be emitted as a transition")
		}
	}
	two := int32(2)
	deployment.Spec.Replicas = &two
	deployment.Generation = 4
	deployment.ResourceVersion = "8"
	collector.onDeployment(deployment)
	deployment.Spec.Replicas = &zero
	deployment.Generation = 5
	deployment.ResourceVersion = "9"
	collector.onDeployment(deployment)

	for _, item := range emitter.events {
		if item.EventType != event.KEDAScaleToZero {
			continue
		}
		if item.Attributes["scaled_object"] != "worker" ||
			item.Attributes["desired_replicas"] != int32(0) ||
			item.Attributes["previous_desired_replicas"] != "2" {
			t.Fatalf("unexpected scale-to-zero event: %#v", item.Attributes)
		}
		if !item.Approximate {
			t.Fatal("Deployment spec observation must be marked approximate")
		}
		return
	}
	t.Fatalf("KEDA scale-to-zero event not emitted: %#v", emitter.events)
}
