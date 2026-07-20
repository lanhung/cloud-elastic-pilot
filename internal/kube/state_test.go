package kube

import "testing"

func TestRunIDDoesNotApplyActiveRunToUnmappedNamespace(t *testing.T) {
	state := NewState("active-run")

	if got := state.RunID("kube-system", nil); got != "" {
		t.Fatalf("unmapped namespace got run %q, want empty", got)
	}
	if got := state.RunID("", nil); got != "active-run" {
		t.Fatalf("cluster-scoped object got run %q, want active-run", got)
	}

	state.SetNamespaceRun("experiment", "namespace-run")
	if got := state.RunID("experiment", nil); got != "namespace-run" {
		t.Fatalf("mapped namespace got run %q, want namespace-run", got)
	}
	if got := state.RunID("other", map[string]string{"hooke.io/run-id": "annotated-run"}); got != "annotated-run" {
		t.Fatalf("annotated object got run %q, want annotated-run", got)
	}
}

func TestPodProvisionMetadata(t *testing.T) {
	state := NewState("")
	state.SetPodProvision("pod-1", ProvisionMetadata{TaskID: "task-1", NodeName: "node-1"})

	got, ok := state.PodProvision("pod-1")
	if !ok {
		t.Fatal("expected provision metadata")
	}
	if got.TaskID != "task-1" || got.NodeName != "node-1" {
		t.Fatalf("unexpected metadata: %#v", got)
	}
}
