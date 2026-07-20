package trace

import "testing"

func TestSamplesIncludeValidZeroDurationIntervals(t *testing.T) {
	trace := PodTrace{
		SyncPodStartNS:     1_000_000_000,
		ContainerStartedNS: 1_000_000_000,
		ReadinessSuccessNS: 1_000_000_000,
		Quality: map[string]any{
			"pod_start_event": "POD_SCHEDULED",
			"app_end_event":   "POD_READY",
		},
	}

	samples := trace.Samples()
	if len(samples) != 2 {
		t.Fatalf("got %d samples, want pod and app samples", len(samples))
	}
	for _, sample := range samples {
		if sample.LatencyMS != 0 {
			t.Fatalf("%s latency = %v, want 0", sample.Layer, sample.LatencyMS)
		}
	}
}

func TestSamplesExcludeReversedIntervals(t *testing.T) {
	trace := PodTrace{
		SyncPodStartNS:     2_000_000_000,
		ContainerStartedNS: 1_000_000_000,
		Quality:            map[string]any{},
	}
	if samples := trace.Samples(); len(samples) != 0 {
		t.Fatalf("got %d samples for reversed interval", len(samples))
	}
}
