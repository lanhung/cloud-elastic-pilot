package trace

type PodTrace struct {
	RunID         string `json:"run_id"`
	PodUID        string `json:"pod_uid"`
	PodName       string `json:"pod_name"`
	Namespace     string `json:"namespace"`
	WorkloadKind  string `json:"workload_kind"`
	WorkloadName  string `json:"workload_name"`
	ContainerName string `json:"container_name"`
	NodeName      string `json:"node_name"`

	TriggerTimeNS      int64 `json:"trigger_time_ns,omitempty"`
	NodeStartNS        int64 `json:"node_start_ns,omitempty"`
	NodeReadyNS        int64 `json:"node_ready_ns,omitempty"`
	ImagePullStartNS   int64 `json:"image_pull_start_ns,omitempty"`
	ImagePullEndNS     int64 `json:"image_pull_end_ns,omitempty"`
	SyncPodStartNS     int64 `json:"sync_pod_start_ns,omitempty"`
	ContainerStartedNS int64 `json:"container_started_ns,omitempty"`
	ReadinessSuccessNS int64 `json:"readiness_success_ns,omitempty"`
	FirstSuccessNS     int64 `json:"first_success_ns,omitempty"`

	NodeLatencyMS  float64        `json:"node_latency_ms,omitempty"`
	ImageLatencyMS float64        `json:"image_latency_ms,omitempty"`
	PodLatencyMS   float64        `json:"pod_latency_ms,omitempty"`
	AppLatencyMS   float64        `json:"app_latency_ms,omitempty"`
	TotalLatencyMS float64        `json:"total_latency_ms,omitempty"`
	Complete       bool           `json:"complete"`
	Quality        map[string]any `json:"quality"`
}

type LayerSample struct {
	Layer       string
	LatencyMS   float64
	Approximate bool
	StartEvent  string
	EndEvent    string
}

func (t PodTrace) Samples() []LayerSample {
	var samples []LayerSample
	approx := func(layer string) bool { value, _ := t.Quality[layer+"_approximate"].(bool); return value }
	if validInterval(t.NodeStartNS, t.NodeReadyNS) {
		samples = append(samples, LayerSample{Layer: "node", LatencyMS: t.NodeLatencyMS, Approximate: approx("node"), StartEvent: stringValue(t.Quality["node_start_event"]), EndEvent: "NODE_READY"})
	}
	if validInterval(t.ImagePullStartNS, t.ImagePullEndNS) {
		samples = append(samples, LayerSample{Layer: "image", LatencyMS: t.ImageLatencyMS, Approximate: approx("image"), StartEvent: "IMAGE_PULL_START", EndEvent: "IMAGE_PULL_END"})
	}
	if validInterval(t.SyncPodStartNS, t.ContainerStartedNS) {
		samples = append(samples, LayerSample{Layer: "pod", LatencyMS: t.PodLatencyMS, Approximate: approx("pod"), StartEvent: stringValue(t.Quality["pod_start_event"]), EndEvent: "CONTAINER_STARTED"})
	}
	if validInterval(t.ContainerStartedNS, t.ReadinessSuccessNS) {
		samples = append(samples, LayerSample{Layer: "app", LatencyMS: t.AppLatencyMS, Approximate: approx("app"), StartEvent: "CONTAINER_STARTED", EndEvent: stringValue(t.Quality["app_end_event"])})
	}
	return samples
}

func validInterval(start, end int64) bool {
	return start > 0 && end >= start
}

func stringValue(value any) string {
	if v, ok := value.(string); ok {
		return v
	}
	return ""
}
