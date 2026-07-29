package kube

import (
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/cache"
)

func TestDRAResourceClaimEmitsSemanticLifecycleAndCorrelatesPod(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{
		cfg:     Config{ClusterID: "cluster"},
		state:   NewState("run"),
		emitter: emitter,
	}
	createdAt := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	allocatedAt := createdAt.Add(2 * time.Second)
	preparedAt := createdAt.Add(4 * time.Second)
	claim := draClaimFixture(createdAt, allocatedAt, preparedAt, true)
	base := event.New("cluster", "run", "", "kubernetes-dynamic-watch", createdAt)
	base.Namespace = "e09"
	base.WorkloadUID = "claim-uid"

	collector.emitDRAResourceClaim(base, claim)
	collector.emitDRAResourceClaim(base, claim)

	gotByType := map[string][]event.Event{}
	for _, item := range emitter.events {
		gotByType[item.EventType] = append(gotByType[item.EventType], item)
	}
	for _, eventType := range []string{
		event.DRAResourceClaimCreated,
		event.DRAResourceClaimAllocated,
		event.DRAResourceClaimReserved,
		event.DRAResourceClaimPrepared,
	} {
		if len(gotByType[eventType]) != 1 {
			t.Fatalf("%s count = %d, want 1: %#v", eventType, len(gotByType[eventType]), emitter.events)
		}
	}
	if got := gotByType[event.DRAResourceClaimAllocated][0]; got.EventTimeNS != allocatedAt.UnixNano() || got.Approximate {
		t.Fatalf("allocation timestamp/precision = %#v", got)
	}
	if got := gotByType[event.DRAResourceClaimPrepared][0]; got.EventTimeNS != preparedAt.UnixNano() || got.Approximate {
		t.Fatalf("prepared timestamp/precision = %#v", got)
	}
	if got := gotByType[event.DRAResourceClaimReserved][0]; got.PodUID != "pod-uid" || got.PodName != "probe" || !got.Approximate {
		t.Fatalf("reservation correlation/precision = %#v", got)
	}
	if got := gotByType[event.DRAResourceClaimCreated][0]; got.PodUID != "" {
		t.Fatalf("creation event must keep its immutable claim identity: %#v", got)
	}
	metadata, ok := collector.state.ResourceClaim("e09", "mig")
	if !ok || metadata.UID != "claim-uid" {
		t.Fatalf("claim metadata = %#v, %v", metadata, ok)
	}
	if !containsString(metadata.DeviceClasses, "mig.nvidia.com") ||
		!containsString(metadata.DeviceIDs, "gpu.nvidia.com/gpu-node/mig-1") {
		t.Fatalf("claim allocation metadata = %#v", metadata)
	}
}

func TestDRAResourceClaimDoesNotInferPreparedWithoutReadyCondition(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState("run"), emitter: emitter}
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	claim := draClaimFixture(at, at.Add(time.Second), time.Time{}, false)
	base := event.New("cluster", "run", "", "kubernetes-dynamic-watch", at)
	base.Namespace = "e09"

	collector.emitDRAResourceClaim(base, claim)

	for _, item := range emitter.events {
		if item.EventType == event.DRAResourceClaimPrepared {
			t.Fatalf("allocation was incorrectly treated as preparation: %#v", item)
		}
	}
}

func TestPodDRAAttributesResolveClaimUIDAndAllocation(t *testing.T) {
	state := NewState("")
	state.SetResourceClaim("e09", "generated-claim", ResourceClaimMetadata{
		UID:           "claim-uid",
		DeviceClasses: []string{"mig.nvidia.com"},
		DeviceIDs:     []string{"gpu.nvidia.com/gpu-node/mig-1"},
		Drivers:       []string{"gpu.nvidia.com"},
	})
	template := "mig-template"
	generated := "generated-claim"
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "e09"},
		Spec: corev1.PodSpec{ResourceClaims: []corev1.PodResourceClaim{{
			Name:                      "gpu",
			ResourceClaimTemplateName: &template,
		}}},
		Status: corev1.PodStatus{ResourceClaimStatuses: []corev1.PodResourceClaimStatus{{
			Name:              "gpu",
			ResourceClaimName: &generated,
		}}},
	}

	attrs := podDRAAttributes(state, pod)

	if !containsAnyString(attrs["resource_claim_names"], "generated-claim") ||
		!containsAnyString(attrs["resource_claim_uids"], "claim-uid") ||
		!containsAnyString(attrs["dra_device_classes"], "mig.nvidia.com") ||
		!containsAnyString(attrs["dra_device_ids"], "gpu.nvidia.com/gpu-node/mig-1") {
		t.Fatalf("unexpected Pod DRA attributes: %#v", attrs)
	}
}

func TestDeletedResourceClaimDoesNotLeaveStalePodCorrelation(t *testing.T) {
	state := NewState("")
	state.SetResourceClaim("e09", "mig", ResourceClaimMetadata{UID: "old-uid"})
	collector := &Collector{state: state}
	claim := &unstructured.Unstructured{}
	claim.SetNamespace("e09")
	claim.SetName("mig")
	claim.SetUID(types.UID("old-uid"))

	collector.onDynamicDelete(
		draResourceCandidates("resourceclaims")[0],
		cache.DeletedFinalStateUnknown{Obj: claim},
	)

	if _, ok := state.ResourceClaim("e09", "mig"); ok {
		t.Fatal("deleted ResourceClaim remained in the correlation cache")
	}
}

func TestDRAResourceSliceTracksPublishedInventoryChanges(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState("run"), emitter: emitter}
	at := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	resourceSlice := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "resource.k8s.io/v1",
		"kind":       "ResourceSlice",
		"metadata": map[string]any{
			"name":              "gpu-node",
			"uid":               "slice-uid",
			"creationTimestamp": at.Format(time.RFC3339Nano),
		},
		"spec": map[string]any{
			"driver":   "gpu.nvidia.com",
			"nodeName": "gpu-node",
			"pool": map[string]any{
				"name":               "gpu-node",
				"generation":         int64(1),
				"resourceSliceCount": int64(1),
			},
			"devices": []any{map[string]any{
				"name": "mig-1",
				"attributes": map[string]any{
					"uuid":    map[string]any{"string": "MIG-11111111-1111-1111-1111-111111111111"},
					"type":    map[string]any{"string": "mig"},
					"profile": map[string]any{"string": "1g.5gb"},
				},
			}},
		},
	}}
	resourceSlice.SetUID(types.UID("slice-uid"))
	resourceSlice.SetCreationTimestamp(metav1.NewTime(at))
	base := event.New("cluster", "run", "", "kubernetes-dynamic-watch", at)
	base.WorkloadUID = "slice-uid"

	collector.emitDRAResourceSlice(base, resourceSlice)
	collector.emitDRAResourceSlice(base, resourceSlice)
	resourceSlice.Object["spec"].(map[string]any)["devices"] = []any{
		map[string]any{"name": "mig-1"},
		map[string]any{"name": "mig-2"},
	}
	collector.emitDRAResourceSlice(base, resourceSlice)

	if len(emitter.events) != 2 {
		t.Fatalf("got %d ResourceSlice events, want creation and update: %#v", len(emitter.events), emitter.events)
	}
	if emitter.events[0].Approximate || emitter.events[0].Attributes["observation"] != "created" {
		t.Fatalf("unexpected initial ResourceSlice event: %#v", emitter.events[0])
	}
	published, ok := emitter.events[0].Attributes["published_devices"].([]draPublishedDevice)
	if !ok || len(published) != 1 ||
		published[0].UUID != "MIG-11111111-1111-1111-1111-111111111111" ||
		published[0].Profile != "1g.5gb" {
		t.Fatalf("ResourceSlice device identity was not preserved: %#v", emitter.events[0].Attributes)
	}
	if !emitter.events[1].Approximate || emitter.events[1].Attributes["observation"] != "updated" {
		t.Fatalf("unexpected updated ResourceSlice event: %#v", emitter.events[1])
	}
}

func TestMIGNodeLabelTransitionsEmitRequestedStartedAndFinished(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState("run"), emitter: emitter}
	requestedAt := time.Date(2026, 1, 2, 3, 4, 5, 123, time.UTC)
	node := &corev1.Node{ObjectMeta: metav1.ObjectMeta{
		Name: "gpu-node",
		UID:  types.UID("node-uid"),
		Labels: map[string]string{
			migCapableLabel:     "true",
			migConfigLabel:      "all-disabled",
			migConfigStateLabel: "success",
			gpuProductLabel:     "NVIDIA-A100-SXM4-40GB",
		},
	}}
	base := event.New("cluster", "run", "", "kubernetes-node-watch", requestedAt)
	base.NodeName = node.Name
	base.NodeUID = string(node.UID)
	collector.emitMIGNodeLifecycle(base, node)

	node.Labels[migConfigLabel] = "all-1g.5gb"
	node.Labels[migConfigStateLabel] = "pending"
	node.Annotations = map[string]string{
		migRequestedAtKey:    requestedAt.Format(time.RFC3339Nano),
		migRequestIDKey:      "request-1",
		migRequestProfileKey: "all-1g.5gb",
		migRunIDKey:          "run",
	}
	collector.emitMIGNodeLifecycle(base, node)
	node.Labels[migConfigStateLabel] = "success"
	node.Labels[gpuCountLabel] = "7"
	collector.emitMIGNodeLifecycle(base, node)
	collector.emitMIGNodeLifecycle(base, node)

	got := map[string]event.Event{}
	for _, item := range emitter.events {
		got[item.EventType] = item
	}
	for _, eventType := range []string{event.MIGReshapeRequested, event.MIGReshapeStarted, event.MIGReshapeFinished} {
		if _, ok := got[eventType]; !ok {
			t.Fatalf("missing %s: %#v", eventType, emitter.events)
		}
	}
	if item := got[event.MIGReshapeRequested]; item.EventTimeNS != requestedAt.UnixNano() || item.Approximate {
		t.Fatalf("request timestamp/precision = %#v", item)
	}
	if !got[event.MIGReshapeStarted].Approximate || !got[event.MIGReshapeFinished].Approximate {
		t.Fatalf("MIG Manager label transitions must be observations: %#v", emitter.events)
	}
	if len(emitter.events) != 3 {
		t.Fatalf("MIG transitions were not deduplicated: %#v", emitter.events)
	}
}

func draClaimFixture(createdAt, allocatedAt, preparedAt time.Time, ready bool) *unstructured.Unstructured {
	status := map[string]any{
		"allocation": map[string]any{
			"allocationTimestamp": allocatedAt.Format(time.RFC3339Nano),
			"devices": map[string]any{"results": []any{map[string]any{
				"request": "gpu",
				"driver":  "gpu.nvidia.com",
				"pool":    "gpu-node",
				"device":  "mig-1",
			}}},
		},
		"reservedFor": []any{map[string]any{
			"resource": "pods",
			"name":     "probe",
			"uid":      "pod-uid",
		}},
	}
	if ready {
		status["devices"] = []any{map[string]any{
			"driver": "gpu.nvidia.com",
			"pool":   "gpu-node",
			"device": "mig-1",
			"conditions": []any{map[string]any{
				"type":               "Ready",
				"status":             "True",
				"lastTransitionTime": preparedAt.Format(time.RFC3339Nano),
			}},
		}}
	}
	claim := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "resource.k8s.io/v1",
		"kind":       "ResourceClaim",
		"metadata": map[string]any{
			"name":              "mig",
			"namespace":         "e09",
			"uid":               "claim-uid",
			"creationTimestamp": createdAt.Format(time.RFC3339Nano),
		},
		"spec": map[string]any{"devices": map[string]any{"requests": []any{map[string]any{
			"name":    "gpu",
			"exactly": map[string]any{"deviceClassName": "mig.nvidia.com"},
		}}}},
		"status": status,
	}}
	claim.SetUID(types.UID("claim-uid"))
	claim.SetCreationTimestamp(metav1.NewTime(createdAt))
	return claim
}

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func containsAnyString(raw any, wanted string) bool {
	values, ok := raw.([]string)
	return ok && containsString(values, wanted)
}
