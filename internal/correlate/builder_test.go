package correlate

import (
	"testing"

	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

func TestBuildTraceMergesPodAndContainerScopedEvents(t *testing.T) {
	makeRow := func(typ string, ts int64, pod, node, container string) mysqlstore.EventRow {
		return mysqlstore.EventRow{Event: event.Event{
			RunID:         "r",
			PodUID:        pod,
			PodName:       "p",
			NodeName:      node,
			ContainerName: container,
			EventType:     typ,
			EventTimeNS:   ts,
			Attributes:    map[string]any{},
		}}
	}
	rows := []mysqlstore.EventRow{
		makeRow(event.PodCreated, 1_000_000_000, "p1", "", ""),
		makeRow(event.PodUnschedulable, 2_000_000_000, "p1", "", ""),
		makeRow(event.PodScheduled, 4_000_000_000, "p1", "n1", ""),
		makeRow(event.NodeReady, 10_000_000_000, "", "n1", ""),
		makeRow(event.ContainerStarted, 12_000_000_000, "p1", "n1", "app"),
		makeRow(event.PodReady, 13_000_000_000, "p1", "n1", ""),
	}
	traces := Builder{}.Build(rows)
	if len(traces) != 1 {
		t.Fatalf("got %d", len(traces))
	}
	if traces[0].ContainerName != "app" {
		t.Fatalf("container name %q", traces[0].ContainerName)
	}
	if traces[0].NodeLatencyMS != 8000 {
		t.Fatalf("node latency %v", traces[0].NodeLatencyMS)
	}
	if traces[0].PodLatencyMS != 8000 {
		t.Fatalf("pod latency %v", traces[0].PodLatencyMS)
	}
	if traces[0].AppLatencyMS != 1000 {
		t.Fatalf("app latency %v", traces[0].AppLatencyMS)
	}
	if !traces[0].Complete {
		t.Fatal("expected complete trace")
	}
}
