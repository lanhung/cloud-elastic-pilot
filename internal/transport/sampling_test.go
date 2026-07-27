package transport

import (
	"testing"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

type recordingEmitter struct {
	items []event.Event
}

func (r *recordingEmitter) Emit(item event.Event) error {
	r.items = append(r.items, item)
	return nil
}

func TestSamplingEmitterPreservesPodTraceDecision(t *testing.T) {
	downstream := &recordingEmitter{}
	sampler, err := NewSamplingEmitter(downstream, 10)
	if err != nil {
		t.Fatal(err)
	}
	base := event.Event{
		ClusterID: "cluster-a",
		RunID:     "run-a",
		PodUID:    "pod-a",
	}
	first := base
	first.EventType = event.PodCreated
	second := base
	second.EventType = event.ContainerStarted

	firstKept := deterministicSample(first, 10)
	secondKept := deterministicSample(second, 10)
	if firstKept != secondKept {
		t.Fatal("events from one Pod received different sample decisions")
	}
	if err := sampler.Emit(first); err != nil {
		t.Fatal(err)
	}
	if err := sampler.Emit(second); err != nil {
		t.Fatal(err)
	}
	want := 0
	if firstKept {
		want = 2
	}
	if len(downstream.items) != want {
		t.Fatalf("downstream received %d events, want %d", len(downstream.items), want)
	}
}

func TestSamplingEmitterBoundaryPercentages(t *testing.T) {
	item := event.Event{ClusterID: "cluster", RunID: "run", PodUID: "pod"}
	if deterministicSample(item, 0) {
		t.Fatal("zero percent kept an event")
	}
	if !deterministicSample(item, 100) {
		t.Fatal("100 percent dropped an event")
	}
	for _, percent := range []int{-1, 101} {
		if _, err := NewSamplingEmitter(&recordingEmitter{}, percent); err == nil {
			t.Fatalf("percent %d was accepted", percent)
		}
	}
}
