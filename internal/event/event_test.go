package event

import (
	"testing"
	"time"
)

func TestHashIgnoresObservedTimeAndEventID(t *testing.T) {
	e := New("c", "01JTEST", PodCreated, "test", time.Unix(1, 2))
	e.PodUID = "pod-1"
	h1, err := e.Hash()
	if err != nil {
		t.Fatal(err)
	}
	e.EventID = "different"
	e.ObservedTimeNS++
	e.SourceTimeNS++
	e.IngestTimeNS++
	zero := int64(0)
	e.ClockOffsetNS = &zero
	e.ClockUncertaintyNS = &zero
	h2, err := e.Hash()
	if err != nil {
		t.Fatal(err)
	}
	if h1 != h2 {
		t.Fatalf("hash changed: %s != %s", h1, h2)
	}
}

func TestNormalizeAndValidateClockCorrection(t *testing.T) {
	source := time.Now().UTC().UnixNano()
	offset := int64(125_000)
	uncertainty := int64(25_000)
	e := Event{
		ClusterID: "c", RunID: "r", EventType: PodCreated,
		SourceTimeNS: source, ObservedTimeNS: source + 1,
		ClockOffsetNS: &offset, ClockUncertaintyNS: &uncertainty,
		SourceComponent: "test",
	}
	e.Normalize()
	if want := source + offset; e.EventTimeNS != want {
		t.Fatalf("event_time_ns = %d, want %d", e.EventTimeNS, want)
	}
	if err := e.Validate(); err != nil {
		t.Fatalf("valid corrected event rejected: %v", err)
	}
	e.EventTimeNS++
	if err := e.Validate(); err == nil {
		t.Fatal("expected inconsistent clock correction to be rejected")
	}
}

func TestValidate(t *testing.T) {
	e := New("", "", "", "", time.Now())
	if err := e.Validate(); err == nil {
		t.Fatal("expected validation error")
	}
}
