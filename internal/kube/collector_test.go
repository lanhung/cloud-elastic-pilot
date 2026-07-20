package kube

import (
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

type recordingEmitter struct {
	events []event.Event
}

func (e *recordingEmitter) Emit(item event.Event) error {
	e.events = append(e.events, item)
	return nil
}

func TestEmitIfChangedAssignsUniqueEventIDs(t *testing.T) {
	emitter := &recordingEmitter{}
	collector := &Collector{state: NewState(""), emitter: emitter}
	base := event.New("cluster", "run", "", "test", time.Now())
	base.PodUID = "pod-uid"

	collector.emitIfChanged(base, event.PodReady, "ready", time.Now(), nil, false)
	collector.emitIfChanged(base, event.ReadinessProbeFirstSuccess, "ready", time.Now(), nil, true)

	if len(emitter.events) != 2 {
		t.Fatalf("got %d events, want 2", len(emitter.events))
	}
	if emitter.events[0].EventID == "" || emitter.events[1].EventID == "" {
		t.Fatal("expected non-empty event IDs")
	}
	if emitter.events[0].EventID == emitter.events[1].EventID {
		t.Fatalf("distinct event types reused event ID %q", emitter.events[0].EventID)
	}
}
