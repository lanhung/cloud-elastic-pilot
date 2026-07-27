package correlate

import (
	"math"
	"testing"

	"github.com/hooke-repro/hooke-ack/internal/elasticity"
	"github.com/hooke-repro/hooke-ack/internal/event"
)

func TestAnalyzeWorkflowsCalculatesCriticalPath(t *testing.T) {
	const (
		uid  = "workflow-uid"
		name = "workflow"
	)
	makeEvent := func(eventType string, at int64, attrs map[string]any) event.Event {
		return event.Event{
			ClusterID: "cluster", RunID: "run", EventType: eventType,
			EventTimeNS: at, SourceTimeNS: at, ObservedTimeNS: at,
			SourceComponent: "test", WorkloadUID: uid, WorkloadName: name,
			Attributes: attrs,
		}
	}
	events := []event.Event{
		makeEvent(event.ArgoWorkflowCreated, 1, map[string]any{"protocol_variant": "tuned"}),
		makeEvent(event.ArgoWorkflowStarted, 1_000_000_000, map[string]any{"phase": "Running"}),
		makeEvent(event.ArgoWorkflowFinished, 7_000_000_000, map[string]any{"phase": "Succeeded"}),
	}
	for _, stage := range []struct {
		id         string
		name       string
		start, end int64
	}{
		{id: "a", name: "a", start: 1_000_000_000, end: 3_000_000_000},
		{id: "b", name: "b", start: 3_000_000_000, end: 7_000_000_000},
		{id: "c", name: "c", start: 3_000_000_000, end: 4_000_000_000},
	} {
		attrs := map[string]any{
			"stage_id": stage.id, "stage_name": stage.name,
			"node_type": "Pod", "phase": "Succeeded",
		}
		events = append(events,
			makeEvent(event.ArgoStageStarted, stage.start, attrs),
			makeEvent(event.ArgoStageFinished, stage.end, attrs),
		)
	}
	for _, edge := range [][2]string{{"a", "b"}, {"a", "c"}} {
		events = append(events, makeEvent(event.ArgoWorkflowEdge, 2, map[string]any{
			"from_stage_id": edge[0], "to_stage_id": edge[1], "dependency_type": "control",
		}))
	}

	analysis, err := AnalyzeWorkflows(events, 10)
	if err != nil {
		t.Fatal(err)
	}
	if analysis.WorkflowCount != 1 || analysis.CompleteCount != 1 {
		t.Fatalf("unexpected analysis counts: %+v", analysis)
	}
	got := analysis.Results[0]
	if got.Variant != "tuned" || got.CriticalPathSeconds != 6 || got.WorkflowDurationSeconds != 6 {
		t.Fatalf("unexpected workflow result: %+v", got)
	}
	if len(got.CriticalPathStageNames) != 2 || got.CriticalPathStageNames[0] != "a" || got.CriticalPathStageNames[1] != "b" {
		t.Fatalf("critical path = %v, want [a b]", got.CriticalPathStageNames)
	}
	if math.Abs(got.PredictedElasticity-got.MeasuredElasticity) > 1e-12 {
		t.Fatalf("predicted=%v measured=%v", got.PredictedElasticity, got.MeasuredElasticity)
	}
	if len(analysis.Edges) != 2 {
		t.Fatalf("edge evidence = %+v", analysis.Edges)
	}
}

func TestAnalyzeWorkflowsKeepsIncompleteWorkflowDiagnostic(t *testing.T) {
	events := []event.Event{{
		ClusterID: "cluster", RunID: "run", EventType: event.ArgoWorkflowStarted,
		EventTimeNS: 1, SourceTimeNS: 1, ObservedTimeNS: 1,
		SourceComponent: "test", WorkloadUID: "uid", WorkloadName: "workflow",
		Attributes: map[string]any{"phase": "Running"},
	}}
	analysis, err := AnalyzeWorkflows(events, 30)
	if err != nil {
		t.Fatal(err)
	}
	if analysis.WorkflowCount != 1 || analysis.CompleteCount != 0 {
		t.Fatalf("unexpected analysis: %+v", analysis)
	}
	if analysis.Results[0].IncompleteOrInvalidCause == "" {
		t.Fatal("incomplete workflow has no diagnostic")
	}
}

func TestCollapseWorkflowEdgesSkipsStructuralNodes(t *testing.T) {
	stageSet := map[string]struct{}{"a": {}, "b": {}, "c": {}}
	raw := map[elasticity.Edge]string{
		{From: "a", To: "task-group"}: "control",
		{From: "task-group", To: "b"}: "control",
		{From: "task-group", To: "c"}: "control",
	}
	got := collapseWorkflowEdges(stageSet, raw)
	if len(got) != 2 {
		t.Fatalf("collapsed edges = %#v", got)
	}
	for _, edge := range []elasticity.Edge{{From: "a", To: "b"}, {From: "a", To: "c"}} {
		if _, ok := got[edge]; !ok {
			t.Fatalf("missing collapsed edge %+v in %#v", edge, got)
		}
	}
}
