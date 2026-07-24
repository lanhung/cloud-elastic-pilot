package main

import (
	"testing"
	"time"
)

func TestBarrierCoordinatorReleasesAtKAndAcceptsLateMembers(t *testing.T) {
	coordinator, err := newBarrierCoordinator(4, 2)
	if err != nil {
		t.Fatal(err)
	}
	firstAt := time.Date(2026, 7, 24, 4, 0, 0, 0, time.UTC)
	first, added, err := coordinator.Join(3, firstAt)
	if err != nil || !added {
		t.Fatalf("first join failed: added=%v err=%v", added, err)
	}
	if first.Released || first.JoinedCount != 1 {
		t.Fatalf("barrier released before k: %#v", first)
	}
	secondAt := firstAt.Add(time.Second)
	second, added, err := coordinator.Join(1, secondAt)
	if err != nil || !added {
		t.Fatalf("second join failed: added=%v err=%v", added, err)
	}
	if !second.Released || second.ReleasedAtNS != secondAt.UnixNano() {
		t.Fatalf("barrier did not release at kth join: %#v", second)
	}
	duplicate, added, err := coordinator.Join(1, secondAt.Add(time.Second))
	if err != nil || added || duplicate.ReleasedAtNS != second.ReleasedAtNS {
		t.Fatalf("duplicate join changed release: added=%v snapshot=%#v err=%v", added, duplicate, err)
	}
	if _, _, err := coordinator.Join(4, time.Now()); err == nil {
		t.Fatal("out-of-range rank accepted")
	}
	_, _, _ = coordinator.Join(0, secondAt.Add(2*time.Second))
	all, _, _ := coordinator.Join(2, secondAt.Add(3*time.Second))
	if all.JoinedCount != 4 {
		t.Fatalf("late members were not retained: %#v", all)
	}
	select {
	case <-coordinator.AllJoined():
	default:
		t.Fatal("all-joined signal was not closed")
	}
}
