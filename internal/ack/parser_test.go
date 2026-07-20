package ack

import (
	"github.com/hooke-repro/hooke-ack/internal/event"
	"testing"
)

func TestParser(t *testing.T) {
	parser, err := NewParser(Config{ClusterID: "ack", DefaultRunID: "run", Rules: []Rule{{Name: "created", EventType: event.ACKProvisionTaskCreated, MatchField: "action", MatchRegex: "(?i)create", EventTimeField: "time", NodeNameField: "node", TaskIDField: "task"}}})
	if err != nil {
		t.Fatal(err)
	}
	events, err := parser.Parse(map[string]any{"action": "CreateNode", "time": "2026-01-01T00:00:00Z", "node": "n1", "task": "t1"})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].NodeName != "n1" {
		t.Fatalf("unexpected events: %#v", events)
	}
}
