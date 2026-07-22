package mysql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"

	"github.com/hooke-repro/hooke-ack/internal/trace"
)

func (s *Store) ReplaceRunTraces(ctx context.Context, runID string, traces []trace.PodTrace) error {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `DELETE FROM trace_edges WHERE run_id=?`, runID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM layer_samples WHERE run_id=?`, runID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM pod_traces WHERE run_id=?`, runID); err != nil {
		return err
	}
	traceStmt, err := tx.PrepareContext(ctx, `
INSERT INTO pod_traces (
 run_id, pod_uid, pod_name, namespace, workload_kind, workload_name,
 container_name, node_name, trigger_time_ns, node_start_ns, node_ready_ns,
 image_pull_start_ns, image_pull_end_ns, image_unpack_start_ns, image_unpack_end_ns,
 sync_pod_start_ns, pod_sandbox_start_ns, pod_sandbox_end_ns, cni_setup_start_ns, cni_setup_end_ns,
 container_started_ns, application_listening_ns, warmup_finished_ns, readiness_success_ns, first_request_ns, first_success_ns,
 node_latency_ms, image_latency_ms, image_unpack_latency_ms, pod_latency_ms, pod_sandbox_latency_ms, cni_latency_ms, app_latency_ms,
 total_latency_ms, measured_union_ms, overlap_ms, unattributed_ms, clock_uncertainty_ms, exact_coverage, invalid_order_count,
 complete, quality
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer traceStmt.Close()
	sampleStmt, err := tx.PrepareContext(ctx, `
INSERT INTO layer_samples(
 run_id, pod_uid, container_name, layer, stage, latency_ms, approximate,
 source_start_event, source_end_event, source_start_event_id, source_end_event_id,
 start_time_ns, end_time_ns,
 overlap_ms, critical_path_ms, clock_uncertainty_ms, primary_sample
) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer sampleStmt.Close()
	edgeStmt, err := tx.PrepareContext(ctx, `
INSERT INTO trace_edges(
 run_id, pod_uid, container_name, edge_index, layer, stage, from_event, to_event, from_event_id, to_event_id,
 start_time_ns, end_time_ns, duration_ms, approximate, overlap_ms, critical_path_ms, clock_uncertainty_ms
) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer edgeStmt.Close()

	for _, podTrace := range traces {
		quality, err := json.Marshal(podTrace.Quality)
		if err != nil {
			return fmt.Errorf("marshal trace quality %s: %w", podTrace.PodUID, err)
		}
		imageEnd := podTrace.ImagePullEndNS
		if podTrace.ImageUnpackEndNS > 0 {
			imageEnd = podTrace.ImageUnpackEndNS
		}
		totalEnd := podTrace.EndTimeNS()
		_, err = traceStmt.ExecContext(ctx,
			podTrace.RunID, podTrace.PodUID, podTrace.PodName, podTrace.Namespace, podTrace.WorkloadKind, podTrace.WorkloadName,
			podTrace.ContainerName, podTrace.NodeName,
			nullInt64(podTrace.TriggerTimeNS), nullInt64(podTrace.NodeStartNS), nullInt64(podTrace.NodeReadyNS),
			nullInt64(podTrace.ImagePullStartNS), nullInt64(podTrace.ImagePullEndNS), nullInt64(podTrace.ImageUnpackStartNS), nullInt64(podTrace.ImageUnpackEndNS),
			nullInt64(podTrace.SyncPodStartNS), nullInt64(podTrace.PodSandboxStartNS), nullInt64(podTrace.PodSandboxEndNS), nullInt64(podTrace.CNISetupStartNS), nullInt64(podTrace.CNISetupEndNS),
			nullInt64(podTrace.ContainerStartedNS), nullInt64(podTrace.ApplicationListenNS), nullInt64(podTrace.WarmupFinishedNS), nullInt64(podTrace.ReadinessSuccessNS), nullInt64(podTrace.FirstRequestNS), nullInt64(podTrace.FirstSuccessNS),
			intervalFloat(podTrace.NodeStartNS, podTrace.NodeReadyNS, podTrace.NodeLatencyMS), intervalFloat(podTrace.ImagePullStartNS, imageEnd, podTrace.ImageLatencyMS),
			intervalFloat(podTrace.ImageUnpackStartNS, podTrace.ImageUnpackEndNS, podTrace.ImageUnpackLatencyMS), intervalFloat(podTrace.SyncPodStartNS, podTrace.ContainerStartedNS, podTrace.PodLatencyMS),
			intervalFloat(podTrace.PodSandboxStartNS, podTrace.PodSandboxEndNS, podTrace.PodSandboxLatencyMS), intervalFloat(podTrace.CNISetupStartNS, podTrace.CNISetupEndNS, podTrace.CNILatencyMS),
			intervalFloat(podTrace.ContainerStartedNS, podTrace.ReadinessSuccessNS, podTrace.AppLatencyMS), intervalFloat(podTrace.TriggerTimeNS, totalEnd, podTrace.TotalLatencyMS),
			intervalFloat(podTrace.TriggerTimeNS, totalEnd, podTrace.MeasuredUnionMS), intervalFloat(podTrace.TriggerTimeNS, totalEnd, podTrace.OverlapMS),
			intervalFloat(podTrace.TriggerTimeNS, totalEnd, podTrace.UnattributedMS), nullFloat64(podTrace.ClockUncertaintyMS), nullableCoverage(podTrace), podTrace.InvalidOrderCount,
			podTrace.Complete, quality,
		)
		if err != nil {
			return fmt.Errorf("insert pod trace %s: %w", podTrace.PodUID, err)
		}
		for _, sample := range podTrace.AllSamples() {
			_, err := sampleStmt.ExecContext(ctx, runID, podTrace.PodUID, podTrace.ContainerName,
				sample.Layer, sample.Stage, sample.LatencyMS, sample.Approximate, sample.StartEvent, sample.EndEvent,
				nullString(sample.StartEventID), nullString(sample.EndEventID),
				sample.StartTimeNS, sample.EndTimeNS, sample.OverlapMS, sample.CriticalPathMS,
				nullFloat64(sample.ClockUncertaintyMS), sample.Primary)
			if err != nil {
				return fmt.Errorf("insert layer sample: %w", err)
			}
		}
		for index, edge := range podTrace.Edges {
			_, err := edgeStmt.ExecContext(ctx, runID, podTrace.PodUID, podTrace.ContainerName, index,
				edge.Layer, edge.Stage, edge.FromEvent, edge.ToEvent, nullString(edge.FromEventID), nullString(edge.ToEventID), edge.StartTimeNS, edge.EndTimeNS,
				edge.DurationMS, edge.Approximate, edge.OverlapMS, edge.CriticalPathMS, nullFloat64(edge.ClockUncertaintyMS))
			if err != nil {
				return fmt.Errorf("insert trace edge: %w", err)
			}
		}
	}
	return tx.Commit()
}

func nullInt64(value int64) any {
	if value == 0 {
		return nil
	}
	return value
}

func nullFloat64(value float64) any {
	if value == 0 {
		return nil
	}
	return value
}

func intervalFloat(start, end int64, value float64) any {
	if start <= 0 || end < start {
		return nil
	}
	return value
}

func nullableCoverage(podTrace trace.PodTrace) any {
	if len(podTrace.Samples()) == 0 {
		return nil
	}
	return podTrace.ExactCoverage
}

func (s *Store) UpsertMetric(ctx context.Context, runID, scope, name string, value float64, unit string, sampleCount int, details any) error {
	payload, err := json.Marshal(details)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `
INSERT INTO metric_results(run_id, scope, metric_name, metric_value, unit, sample_count, details)
VALUES(?,?,?,?,?,?,?)
ON DUPLICATE KEY UPDATE metric_value=VALUES(metric_value), unit=VALUES(unit), sample_count=VALUES(sample_count), details=VALUES(details), calculated_at=UTC_TIMESTAMP(6)`,
		runID, scope, name, value, unit, sampleCount, payload)
	return err
}

type MetricRow struct {
	Scope       string          `json:"scope"`
	Name        string          `json:"name"`
	Value       float64         `json:"value"`
	Unit        string          `json:"unit"`
	SampleCount int             `json:"sample_count"`
	Details     json.RawMessage `json:"details"`
}

func (s *Store) ListMetrics(ctx context.Context, runID string) ([]MetricRow, error) {
	rows, err := s.DB.QueryContext(ctx, `
SELECT scope, metric_name, metric_value, unit, sample_count, details
FROM metric_results WHERE run_id=? ORDER BY scope, metric_name`, runID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []MetricRow
	for rows.Next() {
		var row MetricRow
		if err := rows.Scan(&row.Scope, &row.Name, &row.Value, &row.Unit, &row.SampleCount, &row.Details); err != nil {
			return nil, err
		}
		result = append(result, row)
	}
	return result, rows.Err()
}
