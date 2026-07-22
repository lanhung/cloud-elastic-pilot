package main

import (
	"context"
	_ "embed"
	"fmt"
	"log/slog"
	"os"

	"github.com/hooke-repro/hooke-ack/internal/config"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

//go:embed schema.sql
var schema string

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx := context.Background()
	dsn, err := config.Required("HOOKE_MYSQL_DSN")
	if err != nil {
		logger.Error("configuration", "error", err)
		os.Exit(2)
	}
	store, err := mysqlstore.Open(ctx, dsn)
	if err != nil {
		logger.Error("open mysql", "error", err)
		os.Exit(1)
	}
	defer store.Close()
	if _, err := store.DB.ExecContext(ctx, schema); err != nil {
		logger.Error("apply schema", "error", err)
		os.Exit(1)
	}
	if err := applyCompatibilityMigrations(ctx, store); err != nil {
		logger.Error("apply compatibility migrations", "error", err)
		os.Exit(1)
	}
	logger.Info("schema applied")
}

type columnMigration struct {
	table      string
	column     string
	definition string
}

// CREATE TABLE IF NOT EXISTS does not evolve databases created by earlier
// experiments. These guarded additions keep those immutable raw rows readable
// while adding the v2 timing-quality and v3 four-layer timeline fields. Legacy
// timing values are derived only when queried; migration never rewrites
// accepted raw events.
func applyCompatibilityMigrations(ctx context.Context, store *mysqlstore.Store) error {
	columns := []columnMigration{
		{table: "raw_events", column: "source_time_ns", definition: "BIGINT NULL AFTER event_type"},
		{table: "raw_events", column: "ingest_time_ns", definition: "BIGINT NULL AFTER observed_time_ns"},
		{table: "raw_events", column: "clock_offset_ns", definition: "BIGINT NULL AFTER ingest_time_ns"},
		{table: "raw_events", column: "clock_uncertainty_ns", definition: "BIGINT NULL AFTER clock_offset_ns"},
		{table: "raw_events", column: "source_time", definition: "DATETIME(6) NULL AFTER clock_uncertainty_ns"},
		{table: "raw_events", column: "ingest_time", definition: "DATETIME(6) NULL AFTER observed_time"},
		{table: "pod_traces", column: "image_unpack_start_ns", definition: "BIGINT NULL AFTER image_pull_end_ns"},
		{table: "pod_traces", column: "image_unpack_end_ns", definition: "BIGINT NULL AFTER image_unpack_start_ns"},
		{table: "pod_traces", column: "pod_sandbox_start_ns", definition: "BIGINT NULL AFTER sync_pod_start_ns"},
		{table: "pod_traces", column: "pod_sandbox_end_ns", definition: "BIGINT NULL AFTER pod_sandbox_start_ns"},
		{table: "pod_traces", column: "cni_setup_start_ns", definition: "BIGINT NULL AFTER pod_sandbox_end_ns"},
		{table: "pod_traces", column: "cni_setup_end_ns", definition: "BIGINT NULL AFTER cni_setup_start_ns"},
		{table: "pod_traces", column: "application_listening_ns", definition: "BIGINT NULL AFTER container_started_ns"},
		{table: "pod_traces", column: "warmup_finished_ns", definition: "BIGINT NULL AFTER application_listening_ns"},
		{table: "pod_traces", column: "first_request_ns", definition: "BIGINT NULL AFTER readiness_success_ns"},
		{table: "pod_traces", column: "image_unpack_latency_ms", definition: "DOUBLE NULL AFTER image_latency_ms"},
		{table: "pod_traces", column: "pod_sandbox_latency_ms", definition: "DOUBLE NULL AFTER pod_latency_ms"},
		{table: "pod_traces", column: "cni_latency_ms", definition: "DOUBLE NULL AFTER pod_sandbox_latency_ms"},
		{table: "pod_traces", column: "measured_union_ms", definition: "DOUBLE NULL AFTER total_latency_ms"},
		{table: "pod_traces", column: "overlap_ms", definition: "DOUBLE NULL AFTER measured_union_ms"},
		{table: "pod_traces", column: "unattributed_ms", definition: "DOUBLE NULL AFTER overlap_ms"},
		{table: "pod_traces", column: "clock_uncertainty_ms", definition: "DOUBLE NULL AFTER unattributed_ms"},
		{table: "pod_traces", column: "exact_coverage", definition: "DOUBLE NULL AFTER clock_uncertainty_ms"},
		{table: "pod_traces", column: "invalid_order_count", definition: "INT NOT NULL DEFAULT 0 AFTER exact_coverage"},
		{table: "layer_samples", column: "stage", definition: "VARCHAR(64) NOT NULL DEFAULT '' AFTER layer"},
		{table: "layer_samples", column: "source_start_event_id", definition: "CHAR(26) NULL AFTER source_end_event"},
		{table: "layer_samples", column: "source_end_event_id", definition: "CHAR(26) NULL AFTER source_start_event_id"},
		{table: "layer_samples", column: "start_time_ns", definition: "BIGINT NULL AFTER source_end_event_id"},
		{table: "layer_samples", column: "end_time_ns", definition: "BIGINT NULL AFTER start_time_ns"},
		{table: "layer_samples", column: "overlap_ms", definition: "DOUBLE NOT NULL DEFAULT 0 AFTER end_time_ns"},
		{table: "layer_samples", column: "critical_path_ms", definition: "DOUBLE NOT NULL DEFAULT 0 AFTER overlap_ms"},
		{table: "layer_samples", column: "clock_uncertainty_ms", definition: "DOUBLE NULL AFTER critical_path_ms"},
		{table: "layer_samples", column: "primary_sample", definition: "BOOLEAN NOT NULL DEFAULT TRUE AFTER clock_uncertainty_ms"},
		{table: "trace_edges", column: "from_event_id", definition: "CHAR(26) NULL AFTER to_event"},
		{table: "trace_edges", column: "to_event_id", definition: "CHAR(26) NULL AFTER from_event_id"},
	}
	for _, migration := range columns {
		var count int
		if err := store.DB.QueryRowContext(ctx, `
SELECT COUNT(*) FROM information_schema.columns
WHERE table_schema=DATABASE() AND table_name=? AND column_name=?`, migration.table, migration.column).Scan(&count); err != nil {
			return fmt.Errorf("inspect %s.%s: %w", migration.table, migration.column, err)
		}
		if count != 0 {
			continue
		}
		statement := fmt.Sprintf("ALTER TABLE `%s` ADD COLUMN `%s` %s", migration.table, migration.column, migration.definition)
		if _, err := store.DB.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("add %s.%s: %w", migration.table, migration.column, err)
		}
	}
	if _, err := store.DB.ExecContext(ctx, `
CREATE OR REPLACE VIEW v_trace_quality AS
SELECT run_id,
       COUNT(*) AS trace_count,
       SUM(complete) AS complete_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.node_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_node_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.image_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_image_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.pod_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_pod_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.app_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_app_count,
       SUM(invalid_order_count) AS invalid_order_count,
       AVG(exact_coverage) AS mean_exact_coverage,
       AVG(unattributed_ms) AS mean_unattributed_ms,
       AVG(overlap_ms) AS mean_overlap_ms
FROM pod_traces GROUP BY run_id`); err != nil {
		return fmt.Errorf("refresh trace quality view: %w", err)
	}
	if _, err := store.DB.ExecContext(ctx, `INSERT IGNORE INTO schema_migrations(version) VALUES('000002_event_timing_quality')`); err != nil {
		return fmt.Errorf("record timing migration: %w", err)
	}
	if _, err := store.DB.ExecContext(ctx, `INSERT IGNORE INTO schema_migrations(version) VALUES('000003_four_layer_timeline')`); err != nil {
		return fmt.Errorf("record four-layer timeline migration: %w", err)
	}
	return nil
}
