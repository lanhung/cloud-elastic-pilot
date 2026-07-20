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
	h2, err := e.Hash()
	if err != nil {
		t.Fatal(err)
	}
	if h1 != h2 {
		t.Fatalf("hash changed: %s != %s", h1, h2)
	}
}

func TestValidate(t *testing.T) {
	e := New("", "", "", "", time.Now())
	if err := e.Validate(); err == nil {
		t.Fatal("expected validation error")
	}
}
