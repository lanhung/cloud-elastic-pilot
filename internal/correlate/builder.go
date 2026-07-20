package correlate

import (
	"fmt"
	"sort"

	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
	"github.com/hooke-repro/hooke-ack/internal/trace"
)

type Builder struct{}

type nodeFacts struct {
	ready      int64
	taskID     string
	providerID string
}

type ackTaskFacts struct {
	startNS    int64
	nodeName   string
	instanceID string
}

type imageFacts struct {
	start       int64
	end         int64
	approximate bool
}

type containerFacts struct {
	name      string
	imageRef  string
	startedNS int64
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
				setEarliest(&facts.startNS, e.EventTimeNS)
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
					setEarliest(&facts.ready, e.EventTimeNS)
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
			setEarliest(&state.shared.TriggerTimeNS, e.EventTimeNS)
		case event.PodUnschedulable:
			setEarliest(&state.shared.TriggerTimeNS, e.EventTimeNS)
			if state.shared.NodeStartNS == 0 {
				state.shared.NodeStartNS = e.EventTimeNS
				state.shared.Quality["node_start_event"] = event.PodUnschedulable
				state.shared.Quality["node_approximate"] = true
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
				state.shared.Quality["pod_approximate"] = true
			}
		case event.ImagePullStart, event.ImagePullEnd:
			key := e.ImageRef
			facts := state.images[key]
			if facts == nil {
				facts = &imageFacts{}
				state.images[key] = facts
			}
			if e.EventType == event.ImagePullStart {
				setEarliest(&facts.start, e.EventTimeNS)
			} else {
				setLatest(&facts.end, e.EventTimeNS)
			}
			facts.approximate = facts.approximate || e.Approximate
		case event.SyncPodStart:
			state.shared.SyncPodStartNS = e.EventTimeNS
			state.shared.Quality["pod_start_event"] = event.SyncPodStart
			state.shared.Quality["pod_approximate"] = e.Approximate
		case event.ContainerStarted:
			name := e.ContainerName
			facts := state.containers[name]
			if facts == nil {
				facts = &containerFacts{name: name}
				state.containers[name] = facts
			}
			setEarliest(&facts.startedNS, e.EventTimeNS)
			if facts.imageRef == "" {
				facts.imageRef = e.ImageRef
			}
		case event.ReadinessProbeFirstSuccess:
			setEarliest(&state.shared.ReadinessSuccessNS, e.EventTimeNS)
			state.shared.Quality["app_end_event"] = event.ReadinessProbeFirstSuccess
			state.shared.Quality["app_approximate"] = e.Approximate
		case event.PodReady:
			if state.shared.ReadinessSuccessNS == 0 {
				state.shared.ReadinessSuccessNS = e.EventTimeNS
				state.shared.Quality["app_end_event"] = event.PodReady
				state.shared.Quality["app_approximate"] = true
			}
		case event.FirstSuccessfulResponse:
			setEarliest(&state.shared.FirstSuccessNS, e.EventTimeNS)
		}
	}

	result := make([]trace.PodTrace, 0, len(pods))
	for _, state := range pods {
		shared := state.shared
		applyNodeFacts(&shared, nodes, ackByNode, ackByPod, ackByTask)

		if len(state.containers) == 0 {
			candidate := cloneTrace(shared)
			applyImageFacts(&candidate, state.images, "")
			calculate(&candidate)
			result = append(result, candidate)
			continue
		}
		for _, container := range state.containers {
			candidate := cloneTrace(shared)
			candidate.ContainerName = container.name
			candidate.ContainerStartedNS = container.startedNS
			applyImageFacts(&candidate, state.images, container.imageRef)
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

func applyImageFacts(t *trace.PodTrace, images map[string]*imageFacts, imageRef string) {
	if len(images) == 0 {
		return
	}
	if facts := images[imageRef]; facts != nil && facts.start > 0 && facts.end > 0 {
		t.ImagePullStartNS = facts.start
		t.ImagePullEndNS = facts.end
		t.Quality["image_approximate"] = facts.approximate
		return
	}

	// Kubernetes Event messages do not always use the exact image string from
	// ContainerStatus. For a single-container smoke workload, or when a pod has
	// several image operations, use the first pull and last completion as the
	// pod-level image interval and mark its approximation explicitly.
	var start, end int64
	approximate := false
	for _, facts := range images {
		setEarliest(&start, facts.start)
		setLatest(&end, facts.end)
		approximate = approximate || facts.approximate
	}
	if start > 0 && end > 0 {
		t.ImagePullStartNS = start
		t.ImagePullEndNS = end
		t.Quality["image_approximate"] = approximate
	}
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

func setEarliest(dst *int64, value int64) {
	if value > 0 && (*dst == 0 || value < *dst) {
		*dst = value
	}
}

func setLatest(dst *int64, value int64) {
	if value > *dst {
		*dst = value
	}
}

func ms(start, end int64) float64 {
	if start <= 0 || end <= start {
		return 0
	}
	return float64(end-start) / 1e6
}

func calculate(t *trace.PodTrace) {
	t.NodeLatencyMS = ms(t.NodeStartNS, t.NodeReadyNS)
	t.ImageLatencyMS = ms(t.ImagePullStartNS, t.ImagePullEndNS)
	t.PodLatencyMS = ms(t.SyncPodStartNS, t.ContainerStartedNS)
	t.AppLatencyMS = ms(t.ContainerStartedNS, t.ReadinessSuccessNS)
	end := t.ReadinessSuccessNS
	if t.FirstSuccessNS > end {
		end = t.FirstSuccessNS
	}
	t.TotalLatencyMS = ms(t.TriggerTimeNS, end)
	t.Complete = t.ContainerStartedNS > 0 && t.ReadinessSuccessNS > 0
	if t.NodeStartNS > 0 {
		t.Complete = t.Complete && t.NodeReadyNS > 0
	}
	if t.Quality == nil {
		t.Quality = map[string]any{}
	}
}

func eventAttributeString(item event.Event, key string) string {
	value, _ := item.Attributes[key].(string)
	return value
}

func qualityString(quality map[string]any, key string) string {
	value, _ := quality[key].(string)
	return value
}
