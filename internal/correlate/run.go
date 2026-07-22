package correlate

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/attribution"
	"github.com/hooke-repro/hooke-ack/internal/elasticity"
	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

type Summary struct {
	RunID                  string              `json:"run_id"`
	TraceCount             int                 `json:"trace_count"`
	CompleteCount          int                 `json:"complete_count"`
	ExactTraceCount        int                 `json:"exact_trace_count"`
	InvalidOrderCount      int                 `json:"invalid_order_count"`
	ApplicableLayerCount   int                 `json:"applicable_layer_count"`
	LayerScores            map[string]float64  `json:"layer_scores"`
	TotalElasticity        float64             `json:"total_elasticity"`
	MeanOverlapMS          float64             `json:"mean_overlap_ms"`
	MeanUnattributedMS     float64             `json:"mean_unattributed_ms"`
	MeanClockUncertaintyMS float64             `json:"mean_clock_uncertainty_ms"`
	ClockKnownTraceCount   int                 `json:"clock_known_trace_count"`
	P99MinSampleCount      int                 `json:"p99_min_sample_count"`
	Composition            string              `json:"composition"`
	Bottleneck             string              `json:"bottleneck,omitempty"`
	BottleneckBasis        string              `json:"bottleneck_basis,omitempty"`
	Attribution            *attribution.Report `json:"attribution,omitempty"`
}

const minP99SampleCount = 100

func Execute(ctx context.Context, store *mysqlstore.Store, runID string, sloSeconds float64) (Summary, error) {
	rows, err := store.ListEventsByRun(ctx, runID)
	if err != nil {
		return Summary{}, err
	}
	traces := Builder{}.Build(rows)
	if err := store.ReplaceRunTraces(ctx, runID, traces); err != nil {
		return Summary{}, err
	}
	summary := Summary{
		RunID: runID, TraceCount: len(traces), LayerScores: map[string]float64{},
		P99MinSampleCount: minP99SampleCount,
		Composition:       "diagnostic-product; layer durations are non-additive",
	}
	attributionReport := attribution.Analyze(eventsFromRows(rows), 10*time.Minute)
	if attributionReport.UnschedulablePods > 0 || attributionReport.GroundTruthPods > 0 {
		summary.Attribution = &attributionReport
		if err := storeAttributionMetrics(ctx, store, runID, attributionReport); err != nil {
			return Summary{}, err
		}
	}
	layerSamples := map[string][]float64{}
	criticalSamples := map[string][]float64{}
	overlapSamples := map[string][]float64{}
	mean := map[string]float64{}
	timelineCount := 0
	clockKnownCount := 0
	for _, podTrace := range traces {
		if podTrace.Complete {
			summary.CompleteCount++
		}
		if podTrace.ExactCoverage == 1 && len(podTrace.Samples()) > 0 {
			summary.ExactTraceCount++
		}
		summary.InvalidOrderCount += podTrace.InvalidOrderCount
		if podTrace.TriggerTimeNS > 0 && podTrace.EndTimeNS() >= podTrace.TriggerTimeNS {
			summary.MeanOverlapMS += podTrace.OverlapMS
			summary.MeanUnattributedMS += podTrace.UnattributedMS
			timelineCount++
			if qualityNumber(podTrace.Quality, "clock_uncertainty_known_count") > 0 {
				summary.MeanClockUncertaintyMS += podTrace.ClockUncertaintyMS
				clockKnownCount++
			}
		}
		for _, sample := range podTrace.Samples() {
			layerSamples[sample.Layer] = append(layerSamples[sample.Layer], sample.LatencyMS/1000)
			criticalSamples[sample.Layer] = append(criticalSamples[sample.Layer], sample.CriticalPathMS/1000)
			overlapSamples[sample.Layer] = append(overlapSamples[sample.Layer], sample.OverlapMS/1000)
		}
	}
	if timelineCount > 0 {
		summary.MeanOverlapMS /= float64(timelineCount)
		summary.MeanUnattributedMS /= float64(timelineCount)
	}
	if clockKnownCount > 0 {
		summary.MeanClockUncertaintyMS /= float64(clockKnownCount)
	}
	summary.ClockKnownTraceCount = clockKnownCount
	product := 1.0
	inputs := []elasticity.BottleneckInput{}
	for _, layer := range []string{"node", "image", "pod", "app"} {
		samples := layerSamples[layer]
		if len(samples) == 0 {
			continue
		}
		score, err := elasticity.LayerScore(samples, sloSeconds)
		if err != nil {
			return Summary{}, err
		}
		summary.LayerScores[layer] = score
		summary.ApplicableLayerCount++
		product *= score
		var sum float64
		for _, value := range samples {
			sum += value
		}
		mean[layer] = sum / float64(len(samples))
		criticalMean := arithmeticMean(criticalSamples[layer])
		inputs = append(inputs, elasticity.BottleneckInput{Layer: layer, MeanLatencySeconds: criticalMean, Elasticity: score})
		details := map[string]any{
			"mean_seconds": mean[layer], "mean_critical_path_seconds": criticalMean,
			"mean_overlap_seconds": arithmeticMean(overlapSamples[layer]),
			"p50_seconds":          mustPercentile(samples, .5), "p95_seconds": mustPercentile(samples, .95),
			"slo_seconds": sloSeconds, "p99_min_sample_count": minP99SampleCount,
		}
		if len(samples) >= minP99SampleCount {
			details["p99_seconds"] = mustPercentile(samples, .99)
		} else {
			details["p99_suppressed"] = true
		}
		if err := store.UpsertMetric(ctx, runID, layer, "elasticity", score, "score", len(samples), details); err != nil {
			return Summary{}, err
		}
	}
	summary.TotalElasticity = product
	if len(inputs) > 0 {
		best, scores, err := elasticity.Bottleneck(inputs)
		if err == nil {
			summary.Bottleneck = best
			summary.BottleneckBasis = "mean critical-path contribution divided by layer elasticity"
			if err := store.UpsertMetric(ctx, runID, "total", "bottleneck_score", scores[best], "score", len(inputs), map[string]any{"layer": best, "scores": scores, "basis": summary.BottleneckBasis}); err != nil {
				return Summary{}, err
			}
		}
	}
	if math.IsNaN(product) || math.IsInf(product, 0) {
		return Summary{}, fmt.Errorf("invalid total elasticity")
	}
	if err := store.UpsertMetric(ctx, runID, "total", "elasticity", product, "score", len(traces), summary); err != nil {
		return Summary{}, err
	}
	for _, metric := range []struct {
		name  string
		value float64
		unit  string
		count int
	}{
		{name: "overlap_mean", value: summary.MeanOverlapMS, unit: "ms", count: timelineCount},
		{name: "unattributed_mean", value: summary.MeanUnattributedMS, unit: "ms", count: timelineCount},
		{name: "clock_uncertainty_mean", value: summary.MeanClockUncertaintyMS, unit: "ms", count: clockKnownCount},
		{name: "invalid_order_count", value: float64(summary.InvalidOrderCount), unit: "count", count: len(traces)},
	} {
		if err := store.UpsertMetric(ctx, runID, "quality", metric.name, metric.value, metric.unit, metric.count, summary); err != nil {
			return Summary{}, err
		}
	}
	return summary, nil
}

func eventsFromRows(rows []mysqlstore.EventRow) []event.Event {
	result := make([]event.Event, 0, len(rows))
	for _, row := range rows {
		result = append(result, row.Event)
	}
	return result
}

func storeAttributionMetrics(ctx context.Context, store *mysqlstore.Store, runID string, report attribution.Report) error {
	coverage := []struct {
		name  string
		value float64
		count int
	}{
		{name: "pod_task_id_coverage", value: report.PodTaskIDCoverage, count: report.UnschedulablePods},
		{name: "node_task_id_coverage", value: report.NodeTaskIDCoverage, count: report.ObservedNodes},
		{name: "provider_id_coverage", value: report.ProviderIDCoverage, count: report.ObservedNodes},
		{name: "instance_id_coverage", value: report.InstanceIDCoverage, count: report.UniqueTasks},
	}
	for _, metric := range coverage {
		if err := store.UpsertMetric(ctx, runID, "attribution", metric.name, metric.value, "ratio", metric.count, report); err != nil {
			return err
		}
	}
	if err := store.UpsertMetric(ctx, runID, "attribution", "conflict_count", float64(report.TaskNodeConflictCount), "count", report.GroundTruthPods, report.Conflicts); err != nil {
		return err
	}
	for method, result := range report.Methods {
		values := map[string]float64{
			"precision": result.Precision,
			"recall":    result.Recall,
			"f1":        result.F1,
		}
		for name, value := range values {
			if err := store.UpsertMetric(ctx, runID, "attribution/"+method, name, value, "ratio", report.GroundTruthPods, result); err != nil {
				return err
			}
		}
	}
	return nil
}

func mustPercentile(values []float64, p float64) float64 {
	value, _ := elasticity.Percentile(values, p)
	return value
}

func arithmeticMean(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	var sum float64
	for _, value := range values {
		sum += value
	}
	return sum / float64(len(values))
}

func qualityNumber(quality map[string]any, key string) int64 {
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
