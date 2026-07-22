SET NAMES utf8mb4;
SET time_zone = '+00:00';

CREATE TABLE IF NOT EXISTS schema_migrations (
  version VARCHAR(64) NOT NULL PRIMARY KEY,
  applied_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS clusters (
  cluster_id VARCHAR(64) NOT NULL PRIMARY KEY,
  display_name VARCHAR(128) NOT NULL,
  provider VARCHAR(32) NOT NULL DEFAULT 'aliyun-ack',
  region VARCHAR(64) NULL,
  kubernetes_version VARCHAR(32) NULL,
  metadata JSON NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS experiment_runs (
  run_id CHAR(26) NOT NULL PRIMARY KEY,
  cluster_id VARCHAR(64) NOT NULL,
  name VARCHAR(160) NOT NULL,
  status ENUM('pending','running','completed','failed','cancelled') NOT NULL DEFAULT 'running',
  slo_seconds DOUBLE NOT NULL DEFAULT 30,
  started_at DATETIME(6) NOT NULL,
  ended_at DATETIME(6) NULL,
  labels JSON NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  CONSTRAINT fk_experiment_runs_cluster FOREIGN KEY(cluster_id) REFERENCES clusters(cluster_id),
  INDEX idx_experiment_runs_cluster_time(cluster_id, started_at),
  INDEX idx_experiment_runs_status(status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS raw_events (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  event_id CHAR(26) NOT NULL,
  event_hash CHAR(64) NOT NULL,
  cluster_id VARCHAR(64) NOT NULL,
  run_id CHAR(26) NOT NULL,
  event_type VARCHAR(96) NOT NULL,
  source_time_ns BIGINT NOT NULL,
  event_time_ns BIGINT NOT NULL,
  observed_time_ns BIGINT NOT NULL,
  ingest_time_ns BIGINT NOT NULL,
  clock_offset_ns BIGINT NULL,
  clock_uncertainty_ns BIGINT NULL,
  source_time DATETIME(6) NOT NULL,
  event_time DATETIME(6) NOT NULL,
  observed_time DATETIME(6) NOT NULL,
  ingest_time DATETIME(6) NOT NULL,
  clock_type VARCHAR(24) NOT NULL,
  source_component VARCHAR(96) NOT NULL,
  source_instance VARCHAR(192) NULL,
  namespace VARCHAR(128) NULL,
  workload_kind VARCHAR(64) NULL,
  workload_name VARCHAR(253) NULL,
  workload_uid VARCHAR(128) NULL,
  pod_name VARCHAR(253) NULL,
  pod_uid VARCHAR(128) NULL,
  container_name VARCHAR(253) NULL,
  container_id VARCHAR(255) NULL,
  node_name VARCHAR(253) NULL,
  node_uid VARCHAR(128) NULL,
  resource_version VARCHAR(64) NULL,
  image_ref VARCHAR(1024) NULL,
  image_digest VARCHAR(512) NULL,
  result VARCHAR(64) NULL,
  reason VARCHAR(255) NULL,
  approximate BOOLEAN NOT NULL DEFAULT FALSE,
  attributes JSON NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uk_raw_events_event_id(event_id),
  UNIQUE KEY uk_raw_events_hash(event_hash),
  INDEX idx_raw_events_run_time(run_id,event_time_ns,id),
  INDEX idx_raw_events_pod(run_id,pod_uid,event_time_ns),
  INDEX idx_raw_events_node(run_id,node_name,event_time_ns),
  INDEX idx_raw_events_type(run_id,event_type,event_time_ns),
  INDEX idx_raw_events_workload(run_id,workload_uid,event_time_ns),
  CONSTRAINT fk_raw_events_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS consumer_offsets (
  consumer_name VARCHAR(128) NOT NULL,
  run_id CHAR(26) NOT NULL,
  last_event_id BIGINT NOT NULL DEFAULT 0,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY(consumer_name,run_id),
  CONSTRAINT fk_consumer_offsets_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS node_provision_batches (
  run_id CHAR(26) NOT NULL,
  batch_id VARCHAR(128) NOT NULL,
  provider_task_id VARCHAR(192) NULL,
  node_name VARCHAR(253) NULL,
  instance_id VARCHAR(128) NULL,
  requested_at_ns BIGINT NOT NULL,
  instance_created_at_ns BIGINT NULL,
  instance_running_at_ns BIGINT NULL,
  node_ready_at_ns BIGINT NULL,
  exact_start BOOLEAN NOT NULL DEFAULT FALSE,
  attributes JSON NULL,
  PRIMARY KEY(run_id,batch_id),
  INDEX idx_node_provision_node(run_id,node_name),
  CONSTRAINT fk_node_provision_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS node_provision_batch_pods (
  run_id CHAR(26) NOT NULL,
  batch_id VARCHAR(128) NOT NULL,
  pod_uid VARCHAR(128) NOT NULL,
  workload_uid VARCHAR(128) NULL,
  pod_count_weight DOUBLE NOT NULL DEFAULT 1,
  attributed_latency_ms DOUBLE NULL,
  PRIMARY KEY(run_id,batch_id,pod_uid),
  CONSTRAINT fk_batch_pods_batch FOREIGN KEY(run_id,batch_id) REFERENCES node_provision_batches(run_id,batch_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS pod_traces (
  run_id CHAR(26) NOT NULL,
  pod_uid VARCHAR(128) NOT NULL,
  container_name VARCHAR(253) NOT NULL DEFAULT '',
  pod_name VARCHAR(253) NULL,
  namespace VARCHAR(128) NULL,
  workload_kind VARCHAR(64) NULL,
  workload_name VARCHAR(253) NULL,
  node_name VARCHAR(253) NULL,
  trigger_time_ns BIGINT NULL,
  node_start_ns BIGINT NULL,
  node_ready_ns BIGINT NULL,
  image_pull_start_ns BIGINT NULL,
  image_pull_end_ns BIGINT NULL,
  image_unpack_start_ns BIGINT NULL,
  image_unpack_end_ns BIGINT NULL,
  sync_pod_start_ns BIGINT NULL,
  pod_sandbox_start_ns BIGINT NULL,
  pod_sandbox_end_ns BIGINT NULL,
  cni_setup_start_ns BIGINT NULL,
  cni_setup_end_ns BIGINT NULL,
  container_started_ns BIGINT NULL,
  application_listening_ns BIGINT NULL,
  warmup_finished_ns BIGINT NULL,
  readiness_success_ns BIGINT NULL,
  first_request_ns BIGINT NULL,
  first_success_ns BIGINT NULL,
  node_latency_ms DOUBLE NULL,
  image_latency_ms DOUBLE NULL,
  image_unpack_latency_ms DOUBLE NULL,
  pod_latency_ms DOUBLE NULL,
  pod_sandbox_latency_ms DOUBLE NULL,
  cni_latency_ms DOUBLE NULL,
  app_latency_ms DOUBLE NULL,
  total_latency_ms DOUBLE NULL,
  measured_union_ms DOUBLE NULL,
  overlap_ms DOUBLE NULL,
  unattributed_ms DOUBLE NULL,
  clock_uncertainty_ms DOUBLE NULL,
  exact_coverage DOUBLE NULL,
  invalid_order_count INT NOT NULL DEFAULT 0,
  complete BOOLEAN NOT NULL DEFAULT FALSE,
  quality JSON NULL,
  calculated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY(run_id,pod_uid,container_name),
  INDEX idx_pod_traces_workload(run_id,namespace,workload_name),
  INDEX idx_pod_traces_node(run_id,node_name),
  CONSTRAINT fk_pod_traces_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS layer_samples (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  run_id CHAR(26) NOT NULL,
  pod_uid VARCHAR(128) NOT NULL,
  container_name VARCHAR(253) NOT NULL DEFAULT '',
  layer ENUM('node','image','pod','app','controller','queue','scheduler','gpu') NOT NULL,
  stage VARCHAR(64) NOT NULL DEFAULT '',
  latency_ms DOUBLE NOT NULL,
  approximate BOOLEAN NOT NULL DEFAULT FALSE,
  source_start_event VARCHAR(96) NULL,
  source_end_event VARCHAR(96) NULL,
  source_start_event_id CHAR(26) NULL,
  source_end_event_id CHAR(26) NULL,
  start_time_ns BIGINT NULL,
  end_time_ns BIGINT NULL,
  overlap_ms DOUBLE NOT NULL DEFAULT 0,
  critical_path_ms DOUBLE NOT NULL DEFAULT 0,
  clock_uncertainty_ms DOUBLE NULL,
  primary_sample BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  INDEX idx_layer_samples_run_layer(run_id,layer,latency_ms),
  INDEX idx_layer_samples_pod(run_id,pod_uid),
  CONSTRAINT fk_layer_samples_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS trace_edges (
  run_id CHAR(26) NOT NULL,
  pod_uid VARCHAR(128) NOT NULL,
  container_name VARCHAR(253) NOT NULL DEFAULT '',
  edge_index INT NOT NULL,
  layer VARCHAR(32) NOT NULL,
  stage VARCHAR(64) NOT NULL,
  from_event VARCHAR(96) NOT NULL,
  to_event VARCHAR(96) NOT NULL,
  from_event_id CHAR(26) NULL,
  to_event_id CHAR(26) NULL,
  start_time_ns BIGINT NOT NULL,
  end_time_ns BIGINT NOT NULL,
  duration_ms DOUBLE NOT NULL,
  approximate BOOLEAN NOT NULL DEFAULT FALSE,
  overlap_ms DOUBLE NOT NULL DEFAULT 0,
  critical_path_ms DOUBLE NOT NULL DEFAULT 0,
  clock_uncertainty_ms DOUBLE NULL,
  PRIMARY KEY(run_id,pod_uid,container_name,edge_index),
  INDEX idx_trace_edges_run_layer(run_id,layer,stage),
  CONSTRAINT fk_trace_edges_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS metric_results (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  run_id CHAR(26) NOT NULL,
  scope VARCHAR(96) NOT NULL,
  metric_name VARCHAR(128) NOT NULL,
  metric_value DOUBLE NOT NULL,
  unit VARCHAR(32) NOT NULL,
  sample_count INT NOT NULL DEFAULT 0,
  details JSON NULL,
  calculation_version VARCHAR(64) NOT NULL DEFAULT 'v1',
  calculated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uk_metric_results(run_id,scope,metric_name,calculation_version),
  INDEX idx_metric_results_run(run_id,scope),
  CONSTRAINT fk_metric_results_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS resource_samples (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  run_id CHAR(26) NOT NULL,
  sample_time_ns BIGINT NOT NULL,
  resource_type ENUM('cpu','memory','gpu','network','io') NOT NULL,
  scope_kind VARCHAR(32) NOT NULL,
  scope_name VARCHAR(253) NOT NULL,
  supply DOUBLE NOT NULL,
  demand DOUBLE NOT NULL,
  unit VARCHAR(32) NOT NULL,
  attributes JSON NULL,
  INDEX idx_resource_samples_run_resource(run_id,resource_type,sample_time_ns),
  CONSTRAINT fk_resource_samples_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS workflow_edges (
  run_id CHAR(26) NOT NULL,
  workflow_uid VARCHAR(128) NOT NULL,
  from_stage_id VARCHAR(255) NOT NULL,
  to_stage_id VARCHAR(255) NOT NULL,
  dependency_type VARCHAR(32) NOT NULL DEFAULT 'control',
  PRIMARY KEY(run_id,workflow_uid,from_stage_id,to_stage_id),
  CONSTRAINT fk_workflow_edges_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS tuning_recommendations (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  run_id CHAR(26) NOT NULL,
  rule_name VARCHAR(64) NOT NULL,
  target_kind VARCHAR(64) NOT NULL,
  target_namespace VARCHAR(128) NULL,
  target_name VARCHAR(253) NOT NULL,
  current_value JSON NULL,
  recommended_value JSON NULL,
  expected_gain DOUBLE NULL,
  safety_status ENUM('safe','requires-review','unsupported') NOT NULL DEFAULT 'requires-review',
  yaml_patch MEDIUMTEXT NULL,
  rationale TEXT NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  INDEX idx_tuning_run(run_id,rule_name),
  CONSTRAINT fk_tuning_run FOREIGN KEY(run_id) REFERENCES experiment_runs(run_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE OR REPLACE VIEW v_trace_quality AS
SELECT run_id,
       COUNT(*) AS trace_count,
       SUM(complete) AS complete_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.node_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_node_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.image_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_image_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.pod_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_pod_count,
       SUM(CASE WHEN JSON_EXTRACT(quality,'$.app_approximate') = TRUE THEN 1 ELSE 0 END) AS approximate_app_count
FROM pod_traces GROUP BY run_id;

INSERT IGNORE INTO schema_migrations(version) VALUES('000001_core');
