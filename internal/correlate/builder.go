package correlate

import (
	"fmt"
	"sort"
	"strings"

	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
	"github.com/hooke-repro/hooke-ack/internal/trace"
)

type Builder struct{}

type nodeFacts struct {
	ready              int64
	readyEventID       string
	clockUncertaintyNS int64
	taskID             string
	providerID         string
}

type ackTaskFacts struct {
	startNS            int64
	startEventID       string
	clockUncertaintyNS int64
	nodeName           string
	instanceID         string
}

type imageFacts struct {
	pullStart              int64
	pullStartEventID       string
	pullStartApproximate   bool
	pullEnd                int64
	pullEndEventID         string
	pullEndApproximate     bool
	unpackStart            int64
	unpackStartEventID     string
	unpackStartApproximate bool
	unpackEnd              int64
	unpackEndEventID       string
	unpackEndApproximate   bool
	cacheHit               int64
	cacheHitEventID        string
	cacheHitApproximate    bool
	clockUncertaintyNS     int64
}

type containerFacts struct {
	name               string
	imageRef           string
	imageDigest        string
	startedNS          int64
	startedEventID     string
	clockUncertaintyNS int64
}

type podFacts struct {
	shared     trace.PodTrace
	images     map[string]*imageFacts
	containers map[string]*containerFacts
}

// Build joins pod-level, container-level and node-level facts into one trace per
// pod/container pair. Kubernetes Pod conditions and image Events are pod scoped,
// while ContainerStarted is container scoped; keeping those scopes separate and
// merging at the end prevents the same pod from being split into incomplete
// traces merely because container_name is absent on Pod events.
func (Builder) Build(rows []mysqlstore.EventRow) []trace.PodTrace {
	nodes := map[string]*nodeFacts{}
	ackByNode := map[string]int64{}
	ackByPod := map[string]int64{}
	ackByTask := map[string]*ackTaskFacts{}
	pods := map[string]*podFacts{}

	for _, row := range rows {
		e := row.Event
		switch e.EventType {
		case event.ACKProvisionTaskCreated:
			taskID := eventAttributeString(e, "task_id")
			if taskID != "" {
				facts := ackByTask[taskID]
				if facts == nil {
					facts = &ackTaskFacts{}
					ackByTask[taskID] = facts
				}
				if setEarliest(&facts.startNS, e.EventTimeNS) {
					facts.startEventID = e.EventID
				}
				facts.clockUncertaintyNS = max64(facts.clockUncertaintyNS, eventClockUncertainty(e))
				if facts.nodeName == "" {
					facts.nodeName = e.NodeName
				}
				if facts.instanceID == "" {
					facts.instanceID = eventAttributeString(e, "instance_id")
				}
			}
			if e.NodeName != "" {
				setMapEarliest(ackByNode, e.NodeName, e.EventTimeNS)
			}
			if e.PodUID != "" {
				setMapEarliest(ackByPod, e.PodUID, e.EventTimeNS)
			}
			if raw, ok := e.Attributes["pending_pod_uids"].([]any); ok {
				for _, uid := range raw {
					key := fmt.Sprint(uid)
					if key != "" {
						setMapEarliest(ackByPod, key, e.EventTimeNS)
					}
				}
			}
		case event.NodeCreated, event.NodeReady, event.ACKProvisionTaskUpdated:
			if e.EventType == event.ACKProvisionTaskUpdated && e.PodUID != "" {
				break
			}
			key := e.NodeName
			if key == "" {
				key = e.NodeUID
			}
			if key != "" {
				facts := nodes[key]
				if facts == nil {
					facts = &nodeFacts{}
					nodes[key] = facts
				}
				if e.EventType == event.NodeReady {
					if setEarliest(&facts.ready, e.EventTimeNS) {
						facts.readyEventID = e.EventID
					}
					facts.clockUncertaintyNS = max64(facts.clockUncertaintyNS, eventClockUncertainty(e))
				}
				if facts.taskID == "" {
					facts.taskID = eventAttributeString(e, "task_id")
				}
				if facts.providerID == "" {
					facts.providerID = eventAttributeString(e, "provider_id")
				}
			}
		}

		if e.PodUID == "" {
			continue
		}
		state := pods[e.PodUID]
		if state == nil {
			state = &podFacts{
				shared: trace.PodTrace{
					RunID:   e.RunID,
					PodUID:  e.PodUID,
					PodName: e.PodName,
					Quality: map[string]any{},
				},
				images:     map[string]*imageFacts{},
				containers: map[string]*containerFacts{},
			}
			pods[e.PodUID] = state
		}
		updateSharedMetadata(&state.shared, e)
		observeEventQuality(&state.shared, e)
		if taskID := eventAttributeString(e, "task_id"); taskID != "" {
			if previous := qualityString(state.shared.Quality, "task_id"); previous != "" && previous != taskID {
				state.shared.Quality["task_id_conflict"] = true
				state.shared.Quality["task_id_conflicting_value"] = taskID
			} else {
				state.shared.Quality["task_id"] = taskID
			}
		}
		if nodeName := eventAttributeString(e, "provision_node_name"); nodeName != "" {
			state.shared.Quality["provision_node_name"] = nodeName
		}

		switch e.EventType {
		case event.PodCreated:
			if setEarliest(&state.shared.TriggerTimeNS, e.EventTimeNS) {
				state.shared.Quality["trigger_event_id"] = e.EventID
				state.shared.Quality["trigger_event"] = event.PodCreated
			}
		case event.PodUnschedulable:
			if setEarliest(&state.shared.TriggerTimeNS, e.EventTimeNS) {
				state.shared.Quality["trigger_event_id"] = e.EventID
				state.shared.Quality["trigger_event"] = event.PodUnschedulable
			}
			if state.shared.NodeStartNS == 0 {
				state.shared.NodeStartNS = e.EventTimeNS
				state.shared.Quality["node_start_event"] = event.PodUnschedulable
				state.shared.Quality["node_start_event_id"] = e.EventID
				state.shared.Quality["node_approximate"] = true
				observeLayerClock(&state.shared, "node", e)
			}
		case event.PodScheduled:
			if state.shared.NodeName == "" {
				if value, ok := e.Attributes["node_name"].(string); ok {
					state.shared.NodeName = value
				}
			}
			if state.shared.SyncPodStartNS == 0 {
				state.shared.SyncPodStartNS = e.EventTimeNS
				state.shared.Quality["pod_start_event"] = event.PodScheduled
				state.shared.Quality["pod_start_event_id"] = e.EventID
				state.shared.Quality["pod_approximate"] = true
				observeLayerClock(&state.shared, "pod", e)
			}
		case event.ImagePullStart, event.ImagePullEnd, event.ImageUnpackStart, event.ImageUnpackEnd, event.ImageCacheHit:
			facts := imageFactsForEvent(state.images, e)
			switch e.EventType {
			case event.ImagePullStart:
				setPreferredEarliest(&facts.pullStart, &facts.pullStartEventID, &facts.pullStartApproximate, e)
			case event.ImagePullEnd:
				setPreferredLatest(&facts.pullEnd, &facts.pullEndEventID, &facts.pullEndApproximate, e)
			case event.ImageUnpackStart:
				setPreferredEarliest(&facts.unpackStart, &facts.unpackStartEventID, &facts.unpackStartApproximate, e)
			case event.ImageUnpackEnd:
				setPreferredLatest(&facts.unpackEnd, &facts.unpackEndEventID, &facts.unpackEndApproximate, e)
			case event.ImageCacheHit:
				setPreferredEarliest(&facts.cacheHit, &facts.cacheHitEventID, &facts.cacheHitApproximate, e)
			}
			facts.clockUncertaintyNS = max64(facts.clockUncertaintyNS, eventClockUncertainty(e))
		case event.SyncPodStart:
			state.shared.SyncPodStartNS = e.EventTimeNS
			state.shared.Quality["pod_start_event"] = event.SyncPodStart
			state.shared.Quality["pod_start_event_id"] = e.EventID
			state.shared.Quality["pod_approximate"] = e.Approximate
			observeLayerClock(&state.shared, "pod", e)
		case event.PodSandboxStart:
			if setEarliest(&state.shared.PodSandboxStartNS, e.EventTimeNS) {
				state.shared.Quality["sandbox_start_event_id"] = e.EventID
			}
			state.shared.Quality["sandbox_approximate"] = e.Approximate
			observeLayerClock(&state.shared, "sandbox", e)
			// Managed kubelets do not always log a UID-addressable syncPod entry,
			// while containerd exposes the exact CRI RunPodSandbox boundary. Prefer
			// that real boundary over the approximate PodScheduled fallback. A
			// future exact SYNC_POD_START still wins when it is available.
			podApproximate, _ := state.shared.Quality["pod_approximate"].(bool)
			if state.shared.SyncPodStartNS == 0 || podApproximate {
				state.shared.SyncPodStartNS = e.EventTimeNS
				state.shared.Quality["pod_start_event"] = event.PodSandboxStart
				state.shared.Quality["pod_start_event_id"] = e.EventID
				state.shared.Quality["pod_approximate"] = e.Approximate
				observeLayerClock(&state.shared, "pod", e)
			}
		case event.PodSandboxEnd:
			if setLatest(&state.shared.PodSandboxEndNS, e.EventTimeNS) {
				state.shared.Quality["sandbox_end_event_id"] = e.EventID
			}
			state.shared.Quality["sandbox_approximate"] = e.Approximate
			observeLayerClock(&state.shared, "sandbox", e)
		case event.CNISetupStart:
			if setEarliest(&state.shared.CNISetupStartNS, e.EventTimeNS) {
				state.shared.Quality["cni_start_event_id"] = e.EventID
			}
			state.shared.Quality["cni_approximate"] = e.Approximate
			observeLayerClock(&state.shared, "cni", e)
		case event.CNISetupEnd:
			if setLatest(&state.shared.CNISetupEndNS, e.EventTimeNS) {
				state.shared.Quality["cni_end_event_id"] = e.EventID
			}
			state.shared.Quality["cni_approximate"] = e.Approximate
			observeLayerClock(&state.shared, "cni", e)
		case event.PodSandboxFail:
			appendFailure(&state.shared, "sandbox_failures", e)
		case event.CNISetupFail:
			appendFailure(&state.shared, "cni_failures", e)
		case event.ImagePullFail, event.ImageUnpackFail:
			appendFailure(&state.shared, "image_failures", e)
		case event.ContainerStarted:
			name := e.ContainerName
			facts := state.containers[name]
			if facts == nil {
				facts = &containerFacts{name: name}
				state.containers[name] = facts
			}
			if setEarliest(&facts.startedNS, e.EventTimeNS) {
				facts.startedEventID = e.EventID
			}
			facts.clockUncertaintyNS = max64(facts.clockUncertaintyNS, eventClockUncertainty(e))
			if facts.imageRef == "" {
				facts.imageRef = e.ImageRef
			}
			if facts.imageDigest == "" {
				facts.imageDigest = e.ImageDigest
			}
		case event.ReadinessProbeFirstSuccess:
			setPreferredTraceEndpoint(&state.shared, &state.shared.ReadinessSuccessNS, "app", event.ReadinessProbeFirstSuccess, e)
			observeLayerClock(&state.shared, "app", e)
		case event.PodReady:
			fallback := e
			fallback.Approximate = true
			setPreferredTraceEndpoint(&state.shared, &state.shared.ReadinessSuccessNS, "app", event.PodReady, fallback)
			observeLayerClock(&state.shared, "app", e)
		case event.ApplicationListening:
			if setEarliest(&state.shared.ApplicationListenNS, e.EventTimeNS) {
				state.shared.Quality["application_listening_event_id"] = e.EventID
			}
		case event.WarmupFinished:
			if setEarliest(&state.shared.WarmupFinishedNS, e.EventTimeNS) {
				state.shared.Quality["warmup_finished_event_id"] = e.EventID
			}
		case event.FirstRequestReceived:
			if setEarliest(&state.shared.FirstRequestNS, e.EventTimeNS) {
				state.shared.Quality["first_request_event_id"] = e.EventID
			}
		case event.FirstSuccessfulResponse:
			if setEarliest(&state.shared.FirstSuccessNS, e.EventTimeNS) {
				state.shared.Quality["first_success_event_id"] = e.EventID
			}
		}
	}

	result := make([]trace.PodTrace, 0, len(pods))
	for _, state := range pods {
		shared := state.shared
		applyNodeFacts(&shared, nodes, ackByNode, ackByPod, ackByTask)

		if len(state.containers) == 0 {
			candidate := cloneTrace(shared)
			applyImageFacts(&candidate, state.images, "", "")
			calculate(&candidate)
			result = append(result, candidate)
			continue
		}
		for _, container := range state.containers {
			candidate := cloneTrace(shared)
			candidate.ContainerName = container.name
			candidate.ContainerStartedNS = container.startedNS
			candidate.Quality["container_started_event_id"] = container.startedEventID
			candidate.Quality["pod_clock_uncertainty_ns"] = max64(qualityInt64(candidate.Quality, "pod_clock_uncertainty_ns"), 2*container.clockUncertaintyNS)
			candidate.Quality["app_clock_uncertainty_ns"] = max64(qualityInt64(candidate.Quality, "app_clock_uncertainty_ns"), 2*container.clockUncertaintyNS)
			applyImageFacts(&candidate, state.images, container.imageRef, container.imageDigest)
			calculate(&candidate)
			result = append(result, candidate)
		}
	}

	sort.Slice(result, func(i, j int) bool {
		if result[i].PodUID == result[j].PodUID {
			return result[i].ContainerName < result[j].ContainerName
		}
		return result[i].PodUID < result[j].PodUID
	})
	return result
}

func updateSharedMetadata(t *trace.PodTrace, e event.Event) {
	if t.RunID == "" {
		t.RunID = e.RunID
	}
	if t.PodName == "" {
		t.PodName = e.PodName
	}
	if t.Namespace == "" {
		t.Namespace = e.Namespace
	}
	if t.WorkloadName == "" {
		t.WorkloadName = e.WorkloadName
		t.WorkloadKind = e.WorkloadKind
	}
	if t.NodeName == "" {
		t.NodeName = e.NodeName
	}
}

func applyNodeFacts(t *trace.PodTrace, nodes map[string]*nodeFacts, ackByNode, ackByPod map[string]int64, ackByTask map[string]*ackTaskFacts) {
	podTaskID := qualityString(t.Quality, "task_id")
	if task := ackByTask[podTaskID]; task != nil && task.startNS > 0 {
		t.NodeStartNS = task.startNS
		t.Quality["node_start_event"] = event.ACKProvisionTaskCreated
		t.Quality["node_start_event_id"] = task.startEventID
		t.Quality["node_approximate"] = false
		t.Quality["node_start_task_id"] = podTaskID
		if task.instanceID != "" {
			t.Quality["instance_id"] = task.instanceID
		}
	} else if exact := ackByPod[t.PodUID]; exact > 0 {
		t.NodeStartNS = exact
		t.Quality["node_start_event"] = event.ACKProvisionTaskCreated
		t.Quality["node_approximate"] = false
	}
	if exact := ackByNode[t.NodeName]; podTaskID == "" && exact > 0 && qualityString(t.Quality, "node_start_event") != event.ACKProvisionTaskCreated {
		t.NodeStartNS = exact
		t.Quality["node_start_event"] = event.ACKProvisionTaskCreated
		t.Quality["node_approximate"] = false
	}
	if facts := nodes[t.NodeName]; facts != nil {
		t.NodeReadyNS = facts.ready
		t.Quality["node_end_event"] = event.NodeReady
		t.Quality["node_end_event_id"] = facts.readyEventID
		startUncertainty := int64(0)
		if task := ackByTask[podTaskID]; task != nil {
			startUncertainty = task.clockUncertaintyNS
		}
		t.Quality["node_clock_uncertainty_ns"] = startUncertainty + facts.clockUncertaintyNS
		t.ClockUncertaintyNS = max64(t.ClockUncertaintyNS, startUncertainty, facts.clockUncertaintyNS)
		if facts.taskID != "" {
			t.Quality["node_task_id"] = facts.taskID
		}
		if facts.providerID != "" {
			t.Quality["provider_id"] = facts.providerID
		}
		if podTaskID != "" && facts.taskID != "" {
			t.Quality["node_attribution_method"] = "task-id"
			t.Quality["node_attribution_confidence"] = "exact"
			t.Quality["node_task_match"] = podTaskID == facts.taskID
		} else if provisionNode := qualityString(t.Quality, "provision_node_name"); provisionNode != "" {
			t.Quality["node_attribution_method"] = "provision-node-annotation"
			t.Quality["node_attribution_confidence"] = "high"
			t.Quality["node_name_match"] = provisionNode == t.NodeName
		} else if t.NodeStartNS > 0 {
			t.Quality["node_attribution_method"] = "time-window"
			t.Quality["node_attribution_confidence"] = "low"
		}
	}
}

func applyImageFacts(t *trace.PodTrace, images map[string]*imageFacts, imageRef, imageDigest string) {
	if len(images) == 0 {
		return
	}
	for _, key := range imageLookupKeys(imageRef, imageDigest) {
		if facts := images[key]; facts != nil && applySingleImageFacts(t, facts, false) {
			return
		}
	}

	// Kubernetes Event messages do not always use the exact image string from
	// ContainerStatus. For a single-container smoke workload, or when a pod has
	// several image operations, use the first pull and last completion as the
	// pod-level image interval and mark its approximation explicitly.
	var startFacts, endFacts *imageFacts
	var start, end int64
	keys := make([]string, 0, len(images))
	for key := range images {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	seen := map[*imageFacts]struct{}{}
	for _, key := range keys {
		facts := images[key]
		if _, exists := seen[facts]; exists {
			continue
		}
		seen[facts] = struct{}{}
		candidateStart, candidateEnd := imageInterval(facts)
		if candidateStart <= 0 || candidateEnd <= 0 {
			continue
		}
		if start == 0 || candidateStart < start {
			start = candidateStart
			startFacts = facts
		}
		if candidateEnd > end {
			end = candidateEnd
			endFacts = facts
		}
	}
	if start > 0 && end > 0 {
		t.ImagePullStartNS = start
		if startFacts != nil && startFacts.cacheHit > 0 {
			t.Quality["image_start_event"] = event.ImageCacheHit
			t.Quality["image_start_event_id"] = startFacts.cacheHitEventID
		} else if startFacts != nil && startFacts.pullStart > 0 {
			t.Quality["image_start_event"] = event.ImagePullStart
			t.Quality["image_start_event_id"] = startFacts.pullStartEventID
		} else if startFacts != nil {
			t.Quality["image_start_event"] = event.ImageUnpackStart
			t.Quality["image_start_event_id"] = startFacts.unpackStartEventID
		}
		if endFacts != nil && endFacts.cacheHit > 0 {
			t.ImagePullEndNS = end
			t.Quality["image_end_event"] = event.ImageCacheHit
			t.Quality["image_end_event_id"] = endFacts.cacheHitEventID
		} else if endFacts != nil && endFacts.unpackEnd > 0 && endFacts.unpackEnd == end {
			t.ImageUnpackEndNS = end
			t.Quality["image_end_event"] = event.ImageUnpackEnd
			t.Quality["image_end_event_id"] = endFacts.unpackEndEventID
		} else {
			t.ImagePullEndNS = end
			if endFacts != nil {
				t.Quality["image_end_event"] = event.ImagePullEnd
				t.Quality["image_end_event_id"] = endFacts.pullEndEventID
			}
		}
		t.Quality["image_approximate"] = true
		t.Quality["image_association"] = "pod-envelope"
	}
}

func imageFactsForEvent(images map[string]*imageFacts, item event.Event) *imageFacts {
	keys := imageLookupKeys(item.ImageRef, item.ImageDigest)
	for _, key := range keys {
		if facts := images[key]; facts != nil {
			for _, alias := range keys {
				images[alias] = facts
			}
			return facts
		}
	}
	facts := &imageFacts{}
	for _, key := range keys {
		images[key] = facts
	}
	return facts
}

func imageLookupKeys(imageRef, imageDigest string) []string {
	keys := make([]string, 0, 2)
	if digest := canonicalSHA256(imageDigest, imageRef); digest != "" {
		keys = append(keys, "digest:"+digest)
	}
	if imageRef != "" {
		keys = append(keys, "ref:"+imageRef)
	}
	if len(keys) == 0 {
		keys = append(keys, "unknown")
	}
	return keys
}

func canonicalSHA256(values ...string) string {
	for _, value := range values {
		index := strings.LastIndex(strings.ToLower(value), "sha256:")
		if index < 0 || len(value) < index+71 {
			continue
		}
		candidate := strings.ToLower(value[index : index+71])
		valid := true
		for _, character := range candidate[len("sha256:"):] {
			if !strings.ContainsRune("0123456789abcdef", character) {
				valid = false
				break
			}
		}
		if valid {
			return candidate
		}
	}
	return ""
}

func applySingleImageFacts(t *trace.PodTrace, facts *imageFacts, associationApproximate bool) bool {
	start, end := imageInterval(facts)
	if start <= 0 || end <= 0 {
		return false
	}
	if facts.cacheHit > 0 {
		t.ImagePullStartNS = facts.cacheHit
		t.ImagePullEndNS = facts.cacheHit
		t.Quality["image_start_event"] = event.ImageCacheHit
		t.Quality["image_end_event"] = event.ImageCacheHit
		t.Quality["image_start_event_id"] = facts.cacheHitEventID
		t.Quality["image_end_event_id"] = facts.cacheHitEventID
	} else {
		t.ImagePullStartNS = start
		t.ImagePullEndNS = facts.pullEnd
		t.ImageUnpackStartNS = facts.unpackStart
		t.ImageUnpackEndNS = facts.unpackEnd
		t.Quality["image_unpack_start_event_id"] = facts.unpackStartEventID
		t.Quality["image_unpack_end_event_id"] = facts.unpackEndEventID
		if facts.pullStart > 0 {
			t.Quality["image_start_event"] = event.ImagePullStart
			t.Quality["image_start_event_id"] = facts.pullStartEventID
		} else {
			t.Quality["image_start_event"] = event.ImageUnpackStart
			t.Quality["image_start_event_id"] = facts.unpackStartEventID
		}
		if facts.unpackEnd > 0 {
			t.Quality["image_end_event"] = event.ImageUnpackEnd
			t.Quality["image_end_event_id"] = facts.unpackEndEventID
		} else {
			t.Quality["image_end_event"] = event.ImagePullEnd
			t.Quality["image_end_event_id"] = facts.pullEndEventID
		}
	}
	t.Quality["image_approximate"] = selectedImageApproximate(facts) || associationApproximate
	t.Quality["image_clock_uncertainty_ns"] = 2 * facts.clockUncertaintyNS
	t.ClockUncertaintyNS = max64(t.ClockUncertaintyNS, facts.clockUncertaintyNS)
	return true
}

func selectedImageApproximate(facts *imageFacts) bool {
	if facts.cacheHit > 0 {
		return facts.cacheHitApproximate
	}
	startApproximate := facts.pullStartApproximate
	if facts.pullStart == 0 {
		startApproximate = facts.unpackStartApproximate
	}
	endApproximate := facts.unpackEndApproximate
	if facts.unpackEnd == 0 {
		endApproximate = facts.pullEndApproximate
	}
	return startApproximate || endApproximate
}

func imageInterval(facts *imageFacts) (int64, int64) {
	if facts == nil {
		return 0, 0
	}
	if facts.cacheHit > 0 {
		return facts.cacheHit, facts.cacheHit
	}
	start := facts.pullStart
	if start == 0 {
		start = facts.unpackStart
	}
	end := facts.unpackEnd
	if end == 0 {
		end = facts.pullEnd
	}
	return start, end
}

func cloneTrace(source trace.PodTrace) trace.PodTrace {
	cloned := source
	cloned.Quality = make(map[string]any, len(source.Quality))
	for key, value := range source.Quality {
		cloned.Quality[key] = value
	}
	return cloned
}

func setMapEarliest(values map[string]int64, key string, value int64) {
	if value <= 0 {
		return
	}
	if previous := values[key]; previous == 0 || value < previous {
		values[key] = value
	}
}

func setEarliest(dst *int64, value int64) bool {
	if value > 0 && (*dst == 0 || value < *dst) {
		*dst = value
		return true
	}
	return false
}

func setLatest(dst *int64, value int64) bool {
	if value > *dst {
		*dst = value
		return true
	}
	return false
}

func setPreferredEarliest(timestamp *int64, eventID *string, approximate *bool, item event.Event) {
	if item.EventTimeNS <= 0 {
		return
	}
	if *timestamp == 0 || (*approximate && !item.Approximate) || (*approximate == item.Approximate && item.EventTimeNS < *timestamp) {
		*timestamp = item.EventTimeNS
		*eventID = item.EventID
		*approximate = item.Approximate
	}
}

func setPreferredLatest(timestamp *int64, eventID *string, approximate *bool, item event.Event) {
	if item.EventTimeNS <= 0 {
		return
	}
	if *timestamp == 0 || (*approximate && !item.Approximate) || (*approximate == item.Approximate && item.EventTimeNS > *timestamp) {
		*timestamp = item.EventTimeNS
		*eventID = item.EventID
		*approximate = item.Approximate
	}
}

func setPreferredTraceEndpoint(t *trace.PodTrace, timestamp *int64, qualityPrefix, eventType string, item event.Event) {
	currentApproximate, hasApproximation := t.Quality[qualityPrefix+"_approximate"].(bool)
	if *timestamp == 0 || (hasApproximation && currentApproximate && !item.Approximate) ||
		(hasApproximation && currentApproximate == item.Approximate && item.EventTimeNS < *timestamp) {
		*timestamp = item.EventTimeNS
		t.Quality[qualityPrefix+"_end_event"] = eventType
		t.Quality[qualityPrefix+"_end_event_id"] = item.EventID
		t.Quality[qualityPrefix+"_approximate"] = item.Approximate
	}
}

func calculate(t *trace.PodTrace) {
	t.Finalize()
}

func observeEventQuality(t *trace.PodTrace, item event.Event) {
	t.Quality["event_count"] = qualityInt64(t.Quality, "event_count") + 1
	if item.SourceTimeNS > 0 {
		t.Quality["source_time_count"] = qualityInt64(t.Quality, "source_time_count") + 1
	}
	if item.IngestTimeNS > 0 {
		t.Quality["ingest_time_count"] = qualityInt64(t.Quality, "ingest_time_count") + 1
		lag := item.IngestTimeNS - item.EventTimeNS
		if lag >= 0 {
			t.Quality["max_ingest_lag_ns"] = max64(qualityInt64(t.Quality, "max_ingest_lag_ns"), lag)
		}
	}
	if item.ClockOffsetNS != nil {
		t.Quality["clock_offset_known_count"] = qualityInt64(t.Quality, "clock_offset_known_count") + 1
		absolute := *item.ClockOffsetNS
		if absolute < 0 {
			absolute = -absolute
		}
		t.Quality["max_abs_clock_offset_ns"] = max64(qualityInt64(t.Quality, "max_abs_clock_offset_ns"), absolute)
	}
	if item.ClockUncertaintyNS != nil {
		t.Quality["clock_uncertainty_known_count"] = qualityInt64(t.Quality, "clock_uncertainty_known_count") + 1
		t.ClockUncertaintyNS = max64(t.ClockUncertaintyNS, *item.ClockUncertaintyNS)
		t.Quality["max_clock_uncertainty_ns"] = t.ClockUncertaintyNS
	}
}

func observeLayerClock(t *trace.PodTrace, layer string, item event.Event) {
	uncertainty := eventClockUncertainty(item)
	key := layer + "_endpoint_clock_uncertainty_ns"
	maximum := max64(qualityInt64(t.Quality, key), uncertainty)
	t.Quality[key] = maximum
	// An interval contains two endpoints, so twice the maximum endpoint bound is
	// a conservative interval uncertainty when per-endpoint identity is absent.
	t.Quality[layer+"_clock_uncertainty_ns"] = 2 * maximum
	if item.ClockUncertaintyNS == nil {
		t.Quality[layer+"_clock_uncertainty_unknown"] = true
	}
}

func eventClockUncertainty(item event.Event) int64 {
	if item.ClockUncertaintyNS == nil {
		return 0
	}
	return *item.ClockUncertaintyNS
}

func appendFailure(t *trace.PodTrace, key string, item event.Event) {
	entry := map[string]any{
		"event_id": item.EventID, "event_type": item.EventType,
		"event_time_ns": item.EventTimeNS, "reason": item.Reason,
	}
	if message, ok := item.Attributes["message"].(string); ok {
		entry["message"] = message
	}
	values, _ := t.Quality[key].([]any)
	t.Quality[key] = append(values, entry)
}

func qualityInt64(quality map[string]any, key string) int64 {
	switch value := quality[key].(type) {
	case int:
		return int64(value)
	case int64:
		return value
	case float64:
		return int64(value)
	default:
		return 0
	}
}

func max64(values ...int64) int64 {
	var result int64
	for _, value := range values {
		if value > result {
			result = value
		}
	}
	return result
}

func eventAttributeString(item event.Event, key string) string {
	value, _ := item.Attributes[key].(string)
	return value
}

func qualityString(quality map[string]any, key string) string {
	value, _ := quality[key].(string)
	return value
}
