package elasticity

import (
	"math"
	"testing"
)

func TestLayerScore(t *testing.T) {
	score, err := LayerScore([]float64{30}, 30)
	if err != nil {
		t.Fatal(err)
	}
	if math.Abs(score-math.Exp(-1)) > 1e-9 {
		t.Fatalf("score %v", score)
	}
}
func TestKEDASolve(t *testing.T) {
	tau, err := SolveKEDACooldown(1, 1.5, 5, 0.99, 3600)
	if err != nil {
		t.Fatal(err)
	}
	value, _ := KEDAElasticityBound(1, 1.5, 5, tau)
	if value < 0.99 {
		t.Fatalf("value %v tau %v", value, tau)
	}
}
func TestWorkflow(t *testing.T) {
	result, err := WorkflowCriticalPath([]Stage{{"a", 2, .9}, {"b", 3, .8}, {"c", 1, .7}}, []Edge{{"a", "b"}, {"a", "c"}})
	if err != nil {
		t.Fatal(err)
	}
	if result.DurationSeconds != 5 || len(result.StageIDs) != 2 {
		t.Fatalf("%+v", result)
	}
}
