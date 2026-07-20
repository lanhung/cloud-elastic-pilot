package mysql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/oklog/ulid/v2"
)

type Run struct {
	RunID      string         `json:"run_id"`
	ClusterID  string         `json:"cluster_id"`
	Name       string         `json:"name"`
	Status     string         `json:"status"`
	SLOSeconds float64        `json:"slo_seconds"`
	StartedAt  time.Time      `json:"started_at"`
	EndedAt    *time.Time     `json:"ended_at,omitempty"`
	Labels     map[string]any `json:"labels,omitempty"`
}

func (s *Store) CreateRun(ctx context.Context, run Run) (Run, error) {
	if run.RunID == "" {
		run.RunID = ulid.Make().String()
	}
	if run.Status == "" {
		run.Status = "running"
	}
	if run.StartedAt.IsZero() {
		run.StartedAt = time.Now().UTC()
	}
	if run.SLOSeconds <= 0 {
		run.SLOSeconds = 30
	}
	labels, err := json.Marshal(run.Labels)
	if err != nil {
		return Run{}, err
	}
	_, err = s.DB.ExecContext(ctx, `
INSERT INTO clusters(cluster_id, display_name)
VALUES(?, ?)
ON DUPLICATE KEY UPDATE display_name=VALUES(display_name)`, run.ClusterID, run.ClusterID)
	if err != nil {
		return Run{}, fmt.Errorf("upsert cluster: %w", err)
	}
	_, err = s.DB.ExecContext(ctx, `
INSERT INTO experiment_runs(run_id, cluster_id, name, status, slo_seconds, started_at, labels)
VALUES(?,?,?,?,?,?,?)`, run.RunID, run.ClusterID, run.Name, run.Status, run.SLOSeconds, run.StartedAt, labels)
	if err != nil {
		return Run{}, fmt.Errorf("create run: %w", err)
	}
	return run, nil
}

func (s *Store) StopRun(ctx context.Context, runID string) error {
	result, err := s.DB.ExecContext(ctx, `
UPDATE experiment_runs SET status='completed', ended_at=UTC_TIMESTAMP(6)
WHERE run_id=? AND status='running'`, runID)
	if err != nil {
		return fmt.Errorf("stop run: %w", err)
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *Store) GetRun(ctx context.Context, runID string) (Run, error) {
	var run Run
	var ended sql.NullTime
	var labels []byte
	err := s.DB.QueryRowContext(ctx, `
SELECT run_id, cluster_id, name, status, slo_seconds, started_at, ended_at, labels
FROM experiment_runs WHERE run_id=?`, runID).Scan(
		&run.RunID, &run.ClusterID, &run.Name, &run.Status, &run.SLOSeconds,
		&run.StartedAt, &ended, &labels,
	)
	if err != nil {
		return Run{}, err
	}
	if ended.Valid {
		run.EndedAt = &ended.Time
	}
	if len(labels) > 0 {
		_ = json.Unmarshal(labels, &run.Labels)
	}
	return run, nil
}
