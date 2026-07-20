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
 image_pull_start_ns, image_pull_end_ns, sync_pod_start_ns,
 container_started_ns, readiness_success_ns, first_success_ns,
 node_latency_ms, image_latency_ms, pod_latency_ms, app_latency_ms,
 total_latency_ms, complete, quality
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer traceStmt.Close()
	sampleStmt, err := tx.PrepareContext(ctx, `
INSERT INTO layer_samples(run_id, pod_uid, container_name, layer, latency_ms, approximate, source_start_event, source_end_event)
VALUES(?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer sampleStmt.Close()

	for _, trace := range traces {
		quality, _ := json.Marshal(trace.Quality)
		_, err := traceStmt.ExecContext(ctx,
			trace.RunID, trace.PodUID, trace.PodName, trace.Namespace, trace.WorkloadKind, trace.WorkloadName,
			trace.ContainerName, trace.NodeName,
			nullInt64(trace.TriggerTimeNS), nullInt64(trace.NodeStartNS), nullInt64(trace.NodeReadyNS),
			nullInt64(trace.ImagePullStartNS), nullInt64(trace.ImagePullEndNS), nullInt64(trace.SyncPodStartNS),
			nullInt64(trace.ContainerStartedNS), nullInt64(trace.ReadinessSuccessNS), nullInt64(trace.FirstSuccessNS),
			nullFloat64(trace.NodeLatencyMS), nullFloat64(trace.ImageLatencyMS), nullFloat64(trace.PodLatencyMS), nullFloat64(trace.AppLatencyMS),
			nullFloat64(trace.TotalLatencyMS), trace.Complete, quality,
		)
		if err != nil {
			return fmt.Errorf("insert pod trace %s: %w", trace.PodUID, err)
		}
		for _, sample := range trace.Samples() {
			_, err := sampleStmt.ExecContext(ctx, runID, trace.PodUID, trace.ContainerName,
				sample.Layer, sample.LatencyMS, sample.Approximate, sample.StartEvent, sample.EndEvent)
			if err != nil {
				return fmt.Errorf("insert layer sample: %w", err)
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
