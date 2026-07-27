package mysql

import (
	"context"
	"database/sql"
	"fmt"
)

type WorkflowEdge struct {
	WorkflowUID    string
	FromStageID    string
	ToStageID      string
	DependencyType string
}

func (s *Store) ReplaceWorkflowEdges(ctx context.Context, runID string, edges []WorkflowEdge) error {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return fmt.Errorf("begin workflow edge transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `DELETE FROM workflow_edges WHERE run_id=?`, runID); err != nil {
		return fmt.Errorf("delete workflow edges: %w", err)
	}
	for _, edge := range edges {
		dependencyType := edge.DependencyType
		if dependencyType == "" {
			dependencyType = "control"
		}
		if _, err := tx.ExecContext(ctx, `
INSERT INTO workflow_edges(run_id,workflow_uid,from_stage_id,to_stage_id,dependency_type)
VALUES(?,?,?,?,?)`,
			runID, edge.WorkflowUID, edge.FromStageID, edge.ToStageID, dependencyType,
		); err != nil {
			return fmt.Errorf("insert workflow edge %s -> %s: %w", edge.FromStageID, edge.ToStageID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit workflow edge transaction: %w", err)
	}
	return nil
}
