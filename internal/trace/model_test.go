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

func TestFinalizeAccountsForOverlapAndCriticalContribution(t *testing.T) {
	trace := PodTrace{
		TriggerTimeNS:      1_000_000_000,
		NodeStartNS:        1_000_000_000,
		NodeReadyNS:        5_000_000_000,
		ImagePullStartNS:   3_000_000_000,
		ImagePullEndNS:     7_000_000_000,
		SyncPodStartNS:     7_000_000_000,
		ContainerStartedNS: 9_000_000_000,
		ReadinessSuccessNS: 11_000_000_000,
		Quality:            map[string]any{},
	}

	trace.Finalize()

	if trace.TotalLatencyMS != 10_000 || trace.MeasuredUnionMS != 10_000 {
		t.Fatalf("unexpected total/union: total=%v union=%v", trace.TotalLatencyMS, trace.MeasuredUnionMS)
	}
	if trace.OverlapMS != 2_000 || trace.UnattributedMS != 0 {
		t.Fatalf("unexpected overlap/unattributed: overlap=%v unattributed=%v", trace.OverlapMS, trace.UnattributedMS)
	}
	wantCritical := map[string]float64{"node": 2_000, "image": 4_000, "pod": 2_000, "app": 2_000}
	for layer, want := range wantCritical {
		if got := trace.CriticalPathByLayerMS[layer]; got != want {
			t.Fatalf("%s critical contribution = %v, want %v", layer, got, want)
		}
	}
	if trace.ExactCoverage != 1 || trace.InvalidOrderCount != 0 || !trace.Complete {
		t.Fatalf("unexpected finalized quality: %#v", trace)
	}
}

func TestEndTimeDefaultsToReadiness(t *testing.T) {
	trace := PodTrace{
		ReadinessSuccessNS: 5_000_000_000,
		FirstSuccessNS:     9_000_000_000,
		Quality:            map[string]any{},
	}
	if got := trace.EndTimeNS(); got != trace.ReadinessSuccessNS {
		t.Fatalf("default end = %d, want readiness %d", got, trace.ReadinessSuccessNS)
	}
	trace.Quality["e2e_end_event"] = "FIRST_SUCCESSFUL_RESPONSE"
	if got := trace.EndTimeNS(); got != trace.FirstSuccessNS {
		t.Fatalf("explicit end = %d, want first success %d", got, trace.FirstSuccessNS)
	}
}
