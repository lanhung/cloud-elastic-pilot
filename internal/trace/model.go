package trace

import (
	"encoding/json"
	"sort"
)

type PodTrace struct {
	RunID         string `json:"run_id"`
	PodUID        string `json:"pod_uid"`
	PodName       string `json:"pod_name"`
	Namespace     string `json:"namespace"`
	WorkloadKind  string `json:"workload_kind"`
	WorkloadName  string `json:"workload_name"`
	ContainerName string `json:"container_name"`
	NodeName      string `json:"node_name"`

	TriggerTimeNS       int64 `json:"trigger_time_ns,omitempty"`
	NodeStartNS         int64 `json:"node_start_ns,omitempty"`
	NodeReadyNS         int64 `json:"node_ready_ns,omitempty"`
	ImagePullStartNS    int64 `json:"image_pull_start_ns,omitempty"`
	ImagePullEndNS      int64 `json:"image_pull_end_ns,omitempty"`
	ImageUnpackStartNS  int64 `json:"image_unpack_start_ns,omitempty"`
	ImageUnpackEndNS    int64 `json:"image_unpack_end_ns,omitempty"`
	SyncPodStartNS      int64 `json:"sync_pod_start_ns,omitempty"`
	PodSandboxStartNS   int64 `json:"pod_sandbox_start_ns,omitempty"`
	PodSandboxEndNS     int64 `json:"pod_sandbox_end_ns,omitempty"`
	CNISetupStartNS     int64 `json:"cni_setup_start_ns,omitempty"`
	CNISetupEndNS       int64 `json:"cni_setup_end_ns,omitempty"`
	ContainerStartedNS  int64 `json:"container_started_ns,omitempty"`
	ApplicationListenNS int64 `json:"application_listening_ns,omitempty"`
	WarmupFinishedNS    int64 `json:"warmup_finished_ns,omitempty"`
	ReadinessSuccessNS  int64 `json:"readiness_success_ns,omitempty"`
	FirstRequestNS      int64 `json:"first_request_ns,omitempty"`
	FirstSuccessNS      int64 `json:"first_success_ns,omitempty"`
	ClockUncertaintyNS  int64 `json:"clock_uncertainty_ns,omitempty"`

	NodeLatencyMS        float64 `json:"node_latency_ms,omitempty"`
	ImageLatencyMS       float64 `json:"image_latency_ms,omitempty"`
	ImageUnpackLatencyMS float64 `json:"image_unpack_latency_ms,omitempty"`
	PodLatencyMS         float64 `json:"pod_latency_ms,omitempty"`
	PodSandboxLatencyMS  float64 `json:"pod_sandbox_latency_ms,omitempty"`
	CNILatencyMS         float64 `json:"cni_latency_ms,omitempty"`
	AppLatencyMS         float64 `json:"app_latency_ms,omitempty"`
	TotalLatencyMS       float64 `json:"total_latency_ms,omitempty"`
	MeasuredUnionMS      float64 `json:"measured_union_ms,omitempty"`
	OverlapMS            float64 `json:"overlap_ms,omitempty"`
	UnattributedMS       float64 `json:"unattributed_ms,omitempty"`
	ClockUncertaintyMS   float64 `json:"clock_uncertainty_ms,omitempty"`
	ExactCoverage        float64 `json:"exact_coverage,omitempty"`
	InvalidOrderCount    int     `json:"invalid_order_count"`

	CriticalPathByLayerMS map[string]float64 `json:"critical_path_by_layer_ms,omitempty"`
	OverlapByLayerMS      map[string]float64 `json:"overlap_by_layer_ms,omitempty"`
	Edges                 []TraceEdge        `json:"edges,omitempty"`
	Complete              bool               `json:"complete"`
	Quality               map[string]any     `json:"quality"`
}

type LayerSample struct {
	Layer              string  `json:"layer"`
	Stage              string  `json:"stage"`
	LatencyMS          float64 `json:"latency_ms"`
	Approximate        bool    `json:"approximate"`
	StartEvent         string  `json:"start_event"`
	EndEvent           string  `json:"end_event"`
	StartEventID       string  `json:"start_event_id,omitempty"`
	EndEventID         string  `json:"end_event_id,omitempty"`
	StartTimeNS        int64   `json:"start_time_ns"`
	EndTimeNS          int64   `json:"end_time_ns"`
	OverlapMS          float64 `json:"overlap_ms"`
	CriticalPathMS     float64 `json:"critical_path_ms"`
	ClockUncertaintyMS float64 `json:"clock_uncertainty_ms"`
	Primary            bool    `json:"primary"`
}

// TraceEdge is a queryable event-DAG edge. Parallel layer edges are retained;
// their durations must not be added without accounting for overlap.
type TraceEdge struct {
	Layer              string  `json:"layer"`
	Stage              string  `json:"stage"`
	FromEvent          string  `json:"from_event"`
	ToEvent            string  `json:"to_event"`
	FromEventID        string  `json:"from_event_id,omitempty"`
	ToEventID          string  `json:"to_event_id,omitempty"`
	StartTimeNS        int64   `json:"start_time_ns"`
	EndTimeNS          int64   `json:"end_time_ns"`
	DurationMS         float64 `json:"duration_ms"`
	Approximate        bool    `json:"approximate"`
	OverlapMS          float64 `json:"overlap_ms"`
	CriticalPathMS     float64 `json:"critical_path_ms"`
	ClockUncertaintyMS float64 `json:"clock_uncertainty_ms"`
}

// Samples returns only the four primary Hooke layers. Diagnostic substages such
// as PodSandbox, CNI and image unpack are available through AllSamples.
func (t PodTrace) Samples() []LayerSample {
	var samples []LayerSample
	add := func(layer, stage string, start, end int64, approximate bool, startEvent, endEvent, startEventID, endEventID string) {
		if !validInterval(start, end) {
			return
		}
		samples = append(samples, LayerSample{
			Layer: layer, Stage: stage, LatencyMS: durationMS(start, end),
			Approximate: approximate, StartEvent: startEvent, EndEvent: endEvent,
			StartEventID: startEventID, EndEventID: endEventID,
			StartTimeNS: start, EndTimeNS: end, Primary: true,
			OverlapMS: t.OverlapByLayerMS[layer], CriticalPathMS: t.CriticalPathByLayerMS[layer],
			ClockUncertaintyMS: float64(qualityInt64(t.Quality, layer+"_clock_uncertainty_ns")) / 1e6,
		})
	}
	add("node", "provision", t.NodeStartNS, t.NodeReadyNS, qualityBool(t.Quality, "node_approximate"), stringValue(t.Quality["node_start_event"]), valueOr(stringValue(t.Quality["node_end_event"]), "NODE_READY"), stringValue(t.Quality["node_start_event_id"]), stringValue(t.Quality["node_end_event_id"]))
	add("image", "pull-to-ready", t.ImagePullStartNS, imageEnd(t), qualityBool(t.Quality, "image_approximate"), valueOr(stringValue(t.Quality["image_start_event"]), "IMAGE_PULL_START"), valueOr(stringValue(t.Quality["image_end_event"]), "IMAGE_PULL_END"), stringValue(t.Quality["image_start_event_id"]), stringValue(t.Quality["image_end_event_id"]))
	add("pod", "sync-to-container", t.SyncPodStartNS, t.ContainerStartedNS, qualityBool(t.Quality, "pod_approximate"), stringValue(t.Quality["pod_start_event"]), "CONTAINER_STARTED", stringValue(t.Quality["pod_start_event_id"]), stringValue(t.Quality["container_started_event_id"]))
	add("app", "container-to-ready", t.ContainerStartedNS, t.ReadinessSuccessNS, qualityBool(t.Quality, "app_approximate"), "CONTAINER_STARTED", stringValue(t.Quality["app_end_event"]), stringValue(t.Quality["container_started_event_id"]), stringValue(t.Quality["app_end_event_id"]))
	return samples
}

func (t PodTrace) AllSamples() []LayerSample {
	samples := t.Samples()
	add := func(layer, stage string, start, end int64, approximate bool, startEvent, endEvent, startEventID, endEventID string) {
		if !validInterval(start, end) {
			return
		}
		samples = append(samples, LayerSample{
			Layer: layer, Stage: stage, LatencyMS: durationMS(start, end),
			Approximate: approximate, StartEvent: startEvent, EndEvent: endEvent,
			StartEventID: startEventID, EndEventID: endEventID,
			StartTimeNS: start, EndTimeNS: end, Primary: false,
			ClockUncertaintyMS: float64(qualityInt64(t.Quality, stage+"_clock_uncertainty_ns")) / 1e6,
		})
	}
	add("image", "unpack", t.ImageUnpackStartNS, t.ImageUnpackEndNS, qualityBool(t.Quality, "image_approximate"), "IMAGE_UNPACK_START", "IMAGE_UNPACK_END", stringValue(t.Quality["image_unpack_start_event_id"]), stringValue(t.Quality["image_unpack_end_event_id"]))
	add("pod", "sandbox", t.PodSandboxStartNS, t.PodSandboxEndNS, qualityBool(t.Quality, "sandbox_approximate"), "POD_SANDBOX_START", "POD_SANDBOX_END", stringValue(t.Quality["sandbox_start_event_id"]), stringValue(t.Quality["sandbox_end_event_id"]))
	add("pod", "cni", t.CNISetupStartNS, t.CNISetupEndNS, qualityBool(t.Quality, "cni_approximate"), "CNI_SETUP_START", "CNI_SETUP_END", stringValue(t.Quality["cni_start_event_id"]), stringValue(t.Quality["cni_end_event_id"]))
	return samples
}

// Finalize derives all durations and timeline-quality fields. The primary layer
// durations are retained for Hooke parity, while union/overlap/unattributed
// values prevent callers from assuming those durations are additive.
func (t *PodTrace) Finalize() {
	if t.Quality == nil {
		t.Quality = map[string]any{}
	}
	t.NodeLatencyMS = durationMS(t.NodeStartNS, t.NodeReadyNS)
	t.ImageLatencyMS = durationMS(t.ImagePullStartNS, imageEnd(*t))
	t.ImageUnpackLatencyMS = durationMS(t.ImageUnpackStartNS, t.ImageUnpackEndNS)
	t.PodLatencyMS = durationMS(t.SyncPodStartNS, t.ContainerStartedNS)
	t.PodSandboxLatencyMS = durationMS(t.PodSandboxStartNS, t.PodSandboxEndNS)
	t.CNILatencyMS = durationMS(t.CNISetupStartNS, t.CNISetupEndNS)
	t.AppLatencyMS = durationMS(t.ContainerStartedNS, t.ReadinessSuccessNS)
	end := t.EndTimeNS()
	t.TotalLatencyMS = durationMS(t.TriggerTimeNS, end)
	t.ClockUncertaintyMS = float64(t.ClockUncertaintyNS) / 1e6

	invalid := invalidIntervals(*t, end)
	t.InvalidOrderCount = len(invalid)
	if len(invalid) > 0 {
		t.Quality["invalid_intervals"] = invalid
	}
	t.Quality["negative_latency_count"] = t.InvalidOrderCount

	t.Complete = t.ContainerStartedNS > 0 && t.ReadinessSuccessNS > 0 && t.InvalidOrderCount == 0
	if t.NodeStartNS > 0 {
		t.Complete = t.Complete && t.NodeReadyNS > 0
	}

	t.CriticalPathByLayerMS = map[string]float64{}
	t.OverlapByLayerMS = map[string]float64{}
	t.MeasuredUnionMS, t.OverlapMS, t.UnattributedMS = timeline(t.TriggerTimeNS, end, t.Samples(), t.CriticalPathByLayerMS, t.OverlapByLayerMS)

	primary := t.Samples()
	exact := 0
	for _, sample := range primary {
		if !sample.Approximate {
			exact++
		}
	}
	if len(primary) > 0 {
		t.ExactCoverage = float64(exact) / float64(len(primary))
	}
	t.Quality["primary_layer_count"] = len(primary)
	t.Quality["exact_primary_layer_count"] = exact
	t.Quality["exact_coverage"] = t.ExactCoverage
	t.Quality["timeline_rule"] = "union-with-latest-ending-active-layer-allocation"

	t.Edges = t.Edges[:0]
	for _, sample := range t.AllSamples() {
		t.Edges = append(t.Edges, TraceEdge{
			Layer: sample.Layer, Stage: sample.Stage,
			FromEvent: sample.StartEvent, ToEvent: sample.EndEvent,
			FromEventID: sample.StartEventID, ToEventID: sample.EndEventID,
			StartTimeNS: sample.StartTimeNS, EndTimeNS: sample.EndTimeNS,
			DurationMS: sample.LatencyMS, Approximate: sample.Approximate,
			OverlapMS: sample.OverlapMS, CriticalPathMS: sample.CriticalPathMS,
			ClockUncertaintyMS: sample.ClockUncertaintyMS,
		})
	}
}

// EndTimeNS defaults to readiness. FIRST_SUCCESS is only valid as an e2e end
// when the load generator was armed at the experiment trigger; a post-rollout
// validation request must not inflate R_e2e.
func (t PodTrace) EndTimeNS() int64 {
	if stringValue(t.Quality["e2e_end_event"]) == "FIRST_SUCCESSFUL_RESPONSE" && t.FirstSuccessNS > 0 {
		return t.FirstSuccessNS
	}
	return t.ReadinessSuccessNS
}

func timeline(start, end int64, samples []LayerSample, critical, overlapByLayer map[string]float64) (float64, float64, float64) {
	if !validInterval(start, end) {
		return 0, 0, 0
	}
	type span struct {
		layer string
		start int64
		end   int64
	}
	spans := make([]span, 0, len(samples))
	boundaries := []int64{start, end}
	for _, sample := range samples {
		left := maxInt64(start, sample.StartTimeNS)
		right := minInt64(end, sample.EndTimeNS)
		if right <= left {
			continue
		}
		spans = append(spans, span{layer: sample.Layer, start: left, end: right})
		boundaries = append(boundaries, left, right)
	}
	sort.Slice(boundaries, func(i, j int) bool { return boundaries[i] < boundaries[j] })
	unique := boundaries[:0]
	for _, value := range boundaries {
		if len(unique) == 0 || unique[len(unique)-1] != value {
			unique = append(unique, value)
		}
	}
	var measuredNS, overlapNS, unattributedNS int64
	for i := 0; i+1 < len(unique); i++ {
		left, right := unique[i], unique[i+1]
		segmentNS := right - left
		if segmentNS <= 0 {
			continue
		}
		active := make([]span, 0, len(spans))
		for _, candidate := range spans {
			if candidate.start < right && candidate.end > left {
				active = append(active, candidate)
			}
		}
		if len(active) == 0 {
			unattributedNS += segmentNS
			continue
		}
		measuredNS += segmentNS
		if len(active) > 1 {
			overlapNS += segmentNS
			for _, candidate := range active {
				overlapByLayer[candidate.layer] += float64(segmentNS) / 1e6
			}
		}
		// The latest-ending active edge gates progress at this instant. Ties use
		// a fixed layer order so recomputation is deterministic.
		chosen := active[0]
		for _, candidate := range active[1:] {
			if candidate.end > chosen.end || (candidate.end == chosen.end && layerRank(candidate.layer) > layerRank(chosen.layer)) {
				chosen = candidate
			}
		}
		critical[chosen.layer] += float64(segmentNS) / 1e6
	}
	return float64(measuredNS) / 1e6, float64(overlapNS) / 1e6, float64(unattributedNS) / 1e6
}

func invalidIntervals(t PodTrace, end int64) []string {
	intervals := []struct {
		name       string
		start, end int64
	}{
		{name: "e2e", start: t.TriggerTimeNS, end: end},
		{name: "node", start: t.NodeStartNS, end: t.NodeReadyNS},
		{name: "image", start: t.ImagePullStartNS, end: imageEnd(t)},
		{name: "image_unpack", start: t.ImageUnpackStartNS, end: t.ImageUnpackEndNS},
		{name: "pod", start: t.SyncPodStartNS, end: t.ContainerStartedNS},
		{name: "sandbox", start: t.PodSandboxStartNS, end: t.PodSandboxEndNS},
		{name: "cni", start: t.CNISetupStartNS, end: t.CNISetupEndNS},
		{name: "app", start: t.ContainerStartedNS, end: t.ReadinessSuccessNS},
	}
	var result []string
	for _, interval := range intervals {
		if interval.start > 0 && interval.end > 0 && interval.end < interval.start {
			result = append(result, interval.name)
		}
	}
	return result
}

func imageEnd(t PodTrace) int64 {
	if t.ImageUnpackEndNS > 0 {
		return t.ImageUnpackEndNS
	}
	return t.ImagePullEndNS
}

func validInterval(start, end int64) bool {
	return start > 0 && end >= start
}

func durationMS(start, end int64) float64 {
	if !validInterval(start, end) {
		return 0
	}
	return float64(end-start) / 1e6
}

func stringValue(value any) string {
	if v, ok := value.(string); ok {
		return v
	}
	return ""
}

func qualityBool(quality map[string]any, key string) bool {
	value, _ := quality[key].(bool)
	return value
}

func qualityInt64(quality map[string]any, key string) int64 {
	switch value := quality[key].(type) {
	case int64:
		return value
	case int:
		return int64(value)
	case float64:
		return int64(value)
	case json.Number:
		parsed, _ := value.Int64()
		return parsed
	default:
		return 0
	}
}

func valueOr(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func minInt64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func layerRank(layer string) int {
	switch layer {
	case "node":
		return 1
	case "image":
		return 2
	case "pod":
		return 3
	case "app":
		return 4
	default:
		return 0
	}
}
