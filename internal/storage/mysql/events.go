package mysql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

const insertEventSQL = `
INSERT IGNORE INTO raw_events (
    event_id, event_hash, cluster_id, run_id, event_type,
    event_time_ns, observed_time_ns, event_time, observed_time,
    clock_type, source_component, source_instance,
    namespace, workload_kind, workload_name, workload_uid,
    pod_name, pod_uid, container_name, container_id,
    node_name, node_uid, resource_version,
    image_ref, image_digest, result, reason, approximate, attributes
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`

func (s *Store) InsertEvents(ctx context.Context, events []event.Event) (int64, error) {
	if len(events) == 0 {
		return 0, nil
	}
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{})
	if err != nil {
		return 0, fmt.Errorf("begin event transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.PrepareContext(ctx, insertEventSQL)
	if err != nil {
		return 0, fmt.Errorf("prepare event insert: %w", err)
	}
	defer stmt.Close()

	var inserted int64
	for i := range events {
		events[i].Normalize()
		if err := events[i].Validate(); err != nil {
			return 0, fmt.Errorf("validate event %d: %w", i, err)
		}
		hash, err := events[i].Hash()
		if err != nil {
			return 0, err
		}
		events[i].EventHash = hash
		attrs, err := json.Marshal(events[i].Attributes)
		if err != nil {
			return 0, fmt.Errorf("marshal attributes: %w", err)
		}
		result, err := stmt.ExecContext(ctx,
			events[i].EventID, events[i].EventHash, events[i].ClusterID, events[i].RunID, events[i].EventType,
			events[i].EventTimeNS, events[i].ObservedTimeNS,
			time.Unix(0, events[i].EventTimeNS).UTC(), time.Unix(0, events[i].ObservedTimeNS).UTC(),
			string(events[i].ClockType), events[i].SourceComponent, nullString(events[i].SourceInstance),
			nullString(events[i].Namespace), nullString(events[i].WorkloadKind), nullString(events[i].WorkloadName), nullString(events[i].WorkloadUID),
			nullString(events[i].PodName), nullString(events[i].PodUID), nullString(events[i].ContainerName), nullString(events[i].ContainerID),
			nullString(events[i].NodeName), nullString(events[i].NodeUID), nullString(events[i].ResourceVersion),
			nullString(events[i].ImageRef), nullString(events[i].ImageDigest), nullString(events[i].Result), nullString(events[i].Reason), events[i].Approximate, attrs,
		)
		if err != nil {
			return 0, fmt.Errorf("insert event %s: %w", events[i].EventID, err)
		}
		n, err := result.RowsAffected()
		if err != nil {
			return 0, err
		}
		inserted += n
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit event transaction: %w", err)
	}
	return inserted, nil
}

func nullString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

type EventRow struct {
	ID    int64
	Event event.Event
}

func (s *Store) ListEventsByRun(ctx context.Context, runID string) ([]EventRow, error) {
	rows, err := s.DB.QueryContext(ctx, `
SELECT id, event_id, event_hash, cluster_id, run_id, event_type,
       event_time_ns, observed_time_ns, clock_type, source_component,
       COALESCE(source_instance,''), COALESCE(namespace,''),
       COALESCE(workload_kind,''), COALESCE(workload_name,''), COALESCE(workload_uid,''),
       COALESCE(pod_name,''), COALESCE(pod_uid,''), COALESCE(container_name,''), COALESCE(container_id,''),
       COALESCE(node_name,''), COALESCE(node_uid,''), COALESCE(resource_version,''),
       COALESCE(image_ref,''), COALESCE(image_digest,''), COALESCE(result,''), COALESCE(reason,''),
       approximate, attributes
FROM raw_events
WHERE run_id = ?
ORDER BY event_time_ns, id`, runID)
	if err != nil {
		return nil, fmt.Errorf("query events: %w", err)
	}
	defer rows.Close()

	var result []EventRow
	for rows.Next() {
		var item event.Event
		var id int64
		var clock string
		var attrs []byte
		if err := rows.Scan(
			&id, &item.EventID, &item.EventHash, &item.ClusterID, &item.RunID, &item.EventType,
			&item.EventTimeNS, &item.ObservedTimeNS, &clock, &item.SourceComponent,
			&item.SourceInstance, &item.Namespace,
			&item.WorkloadKind, &item.WorkloadName, &item.WorkloadUID,
			&item.PodName, &item.PodUID, &item.ContainerName, &item.ContainerID,
			&item.NodeName, &item.NodeUID, &item.ResourceVersion,
			&item.ImageRef, &item.ImageDigest, &item.Result, &item.Reason,
			&item.Approximate, &attrs,
		); err != nil {
			return nil, fmt.Errorf("scan event: %w", err)
		}
		item.ClockType = event.ClockType(clock)
		if len(attrs) > 0 {
			if err := json.Unmarshal(attrs, &item.Attributes); err != nil {
				return nil, fmt.Errorf("unmarshal event attributes: %w", err)
			}
		}
		result = append(result, EventRow{ID: id, Event: item})
	}
	return result, rows.Err()
}
