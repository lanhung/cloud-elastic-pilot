package event

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/oklog/ulid/v2"
)

type ClockType string

const (
	ClockRealtime  ClockType = "realtime"
	ClockMonotonic ClockType = "monotonic"
	ClockAPIServer ClockType = "apiserver"
	ClockSource    ClockType = "source"
)

type Event struct {
	EventID         string         `json:"event_id,omitempty"`
	EventHash       string         `json:"event_hash,omitempty"`
	ClusterID       string         `json:"cluster_id"`
	RunID           string         `json:"run_id"`
	EventType       string         `json:"event_type"`
	EventTimeNS     int64          `json:"event_time_ns"`
	ObservedTimeNS  int64          `json:"observed_time_ns,omitempty"`
	ClockType       ClockType      `json:"clock_type,omitempty"`
	SourceComponent string         `json:"source_component"`
	SourceInstance  string         `json:"source_instance,omitempty"`
	Namespace       string         `json:"namespace,omitempty"`
	WorkloadKind    string         `json:"workload_kind,omitempty"`
	WorkloadName    string         `json:"workload_name,omitempty"`
	WorkloadUID     string         `json:"workload_uid,omitempty"`
	PodName         string         `json:"pod_name,omitempty"`
	PodUID          string         `json:"pod_uid,omitempty"`
	ContainerName   string         `json:"container_name,omitempty"`
	ContainerID     string         `json:"container_id,omitempty"`
	NodeName        string         `json:"node_name,omitempty"`
	NodeUID         string         `json:"node_uid,omitempty"`
	ResourceVersion string         `json:"resource_version,omitempty"`
	ImageRef        string         `json:"image_ref,omitempty"`
	ImageDigest     string         `json:"image_digest,omitempty"`
	Result          string         `json:"result,omitempty"`
	Reason          string         `json:"reason,omitempty"`
	Approximate     bool           `json:"approximate,omitempty"`
	Attributes      map[string]any `json:"attributes,omitempty"`
}

func New(clusterID, runID, eventType, source string, at time.Time) Event {
	now := time.Now().UTC()
	if at.IsZero() {
		at = now
	}
	return Event{
		EventID:         ulid.Make().String(),
		ClusterID:       clusterID,
		RunID:           runID,
		EventType:       eventType,
		EventTimeNS:     at.UTC().UnixNano(),
		ObservedTimeNS:  now.UnixNano(),
		ClockType:       ClockRealtime,
		SourceComponent: source,
		Attributes:      map[string]any{},
	}
}

func (e *Event) Normalize() {
	if e.EventID == "" {
		e.EventID = ulid.Make().String()
	}
	if e.EventTimeNS == 0 {
		e.EventTimeNS = time.Now().UTC().UnixNano()
	}
	if e.ObservedTimeNS == 0 {
		e.ObservedTimeNS = time.Now().UTC().UnixNano()
	}
	if e.ClockType == "" {
		e.ClockType = ClockRealtime
	}
	if e.Attributes == nil {
		e.Attributes = map[string]any{}
	}
	e.EventType = strings.ToUpper(strings.TrimSpace(e.EventType))
}

func (e Event) Validate() error {
	var missing []string
	if strings.TrimSpace(e.ClusterID) == "" {
		missing = append(missing, "cluster_id")
	}
	if strings.TrimSpace(e.RunID) == "" {
		missing = append(missing, "run_id")
	}
	if strings.TrimSpace(e.EventType) == "" {
		missing = append(missing, "event_type")
	}
	if strings.TrimSpace(e.SourceComponent) == "" {
		missing = append(missing, "source_component")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required fields: %s", strings.Join(missing, ", "))
	}
	if e.EventTimeNS <= 0 {
		return errors.New("event_time_ns must be positive")
	}
	if e.EventTimeNS > time.Now().Add(10*time.Minute).UnixNano() {
		return errors.New("event_time_ns is more than 10 minutes in the future")
	}
	return nil
}

func (e Event) Hash() (string, error) {
	canonical := struct {
		ClusterID       string         `json:"cluster_id"`
		RunID           string         `json:"run_id"`
		EventType       string         `json:"event_type"`
		EventTimeNS     int64          `json:"event_time_ns"`
		SourceComponent string         `json:"source_component"`
		SourceInstance  string         `json:"source_instance"`
		Namespace       string         `json:"namespace"`
		WorkloadUID     string         `json:"workload_uid"`
		PodUID          string         `json:"pod_uid"`
		ContainerName   string         `json:"container_name"`
		ContainerID     string         `json:"container_id"`
		NodeUID         string         `json:"node_uid"`
		ResourceVersion string         `json:"resource_version"`
		ImageRef        string         `json:"image_ref"`
		Reason          string         `json:"reason"`
		Attributes      map[string]any `json:"attributes"`
	}{
		ClusterID: e.ClusterID, RunID: e.RunID, EventType: e.EventType,
		EventTimeNS: e.EventTimeNS, SourceComponent: e.SourceComponent,
		SourceInstance: e.SourceInstance, Namespace: e.Namespace,
		WorkloadUID: e.WorkloadUID, PodUID: e.PodUID,
		ContainerName: e.ContainerName, ContainerID: e.ContainerID,
		NodeUID: e.NodeUID, ResourceVersion: e.ResourceVersion,
		ImageRef: e.ImageRef, Reason: e.Reason, Attributes: e.Attributes,
	}
	payload, err := json.Marshal(canonical)
	if err != nil {
		return "", fmt.Errorf("marshal canonical event: %w", err)
	}
	sum := sha256.Sum256(payload)
	return hex.EncodeToString(sum[:]), nil
}
