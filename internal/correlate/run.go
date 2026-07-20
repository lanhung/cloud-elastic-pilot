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
	RunID           string              `json:"run_id"`
	TraceCount      int                 `json:"trace_count"`
	CompleteCount   int                 `json:"complete_count"`
	LayerScores     map[string]float64  `json:"layer_scores"`
	TotalElasticity float64             `json:"total_elasticity"`
	Bottleneck      string              `json:"bottleneck,omitempty"`
	Attribution     *attribution.Report `json:"attribution,omitempty"`
}

func Execute(ctx context.Context, store *mysqlstore.Store, runID string, sloSeconds float64) (Summary, error) {
	rows, err := store.ListEventsByRun(ctx, runID)
	if err != nil {
		return Summary{}, err
	}
	traces := Builder{}.Build(rows)
	if err := store.ReplaceRunTraces(ctx, runID, traces); err != nil {
		return Summary{}, err
	}
	summary := Summary{RunID: runID, TraceCount: len(traces), LayerScores: map[string]float64{}}
	attributionReport := attribution.Analyze(eventsFromRows(rows), 10*time.Minute)
	if attributionReport.UnschedulablePods > 0 || attributionReport.GroundTruthPods > 0 {
		summary.Attribution = &attributionReport
		if err := storeAttributionMetrics(ctx, store, runID, attributionReport); err != nil {
			return Summary{}, err
		}
	}
	layerSamples := map[string][]float64{}
	mean := map[string]float64{}
	for _, trace := range traces {
		if trace.Complete {
			summary.CompleteCount++
		}
		for _, sample := range trace.Samples() {
			layerSamples[sample.Layer] = append(layerSamples[sample.Layer], sample.LatencyMS/1000)
		}
	}
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
		product *= score
		var sum float64
		for _, value := range samples {
			sum += value
		}
		mean[layer] = sum / float64(len(samples))
		inputs = append(inputs, elasticity.BottleneckInput{Layer: layer, MeanLatencySeconds: mean[layer], Elasticity: score})
		details := map[string]any{"mean_seconds": mean[layer], "p50_seconds": mustPercentile(samples, .5), "p95_seconds": mustPercentile(samples, .95), "p99_seconds": mustPercentile(samples, .99), "slo_seconds": sloSeconds}
		if err := store.UpsertMetric(ctx, runID, layer, "elasticity", score, "score", len(samples), details); err != nil {
			return Summary{}, err
		}
	}
	summary.TotalElasticity = product
	if len(inputs) > 0 {
		best, scores, err := elasticity.Bottleneck(inputs)
		if err == nil {
			summary.Bottleneck = best
			_ = store.UpsertMetric(ctx, runID, "total", "bottleneck_score", scores[best], "score", len(inputs), map[string]any{"layer": best, "scores": scores})
		}
	}
	if math.IsNaN(product) || math.IsInf(product, 0) {
		return Summary{}, fmt.Errorf("invalid total elasticity")
	}
	if err := store.UpsertMetric(ctx, runID, "total", "elasticity", product, "score", len(traces), summary); err != nil {
		return Summary{}, err
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
