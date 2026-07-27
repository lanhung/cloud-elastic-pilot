package main

import (
	"testing"
	"time"
)

func TestStageConfigValidation(t *testing.T) {
	valid := stageConfig{
		StageName: "b", Variant: "tuned", WorkDuration: time.Second,
		Predecessors: []string{"a"}, DependencyProof: "independent-of-c",
	}
	if err := valid.validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	tests := []struct {
		name   string
		mutate func(*stageConfig)
	}{
		{name: "stage", mutate: func(cfg *stageConfig) { cfg.StageName = "B" }},
		{name: "variant", mutate: func(cfg *stageConfig) { cfg.Variant = "unknown" }},
		{name: "duration", mutate: func(cfg *stageConfig) { cfg.WorkDuration = 0 }},
		{name: "self dependency", mutate: func(cfg *stageConfig) { cfg.Predecessors = []string{"b"} }},
		{name: "proof", mutate: func(cfg *stageConfig) { cfg.DependencyProof = "" }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := valid
			test.mutate(&cfg)
			if err := cfg.validate(); err == nil {
				t.Fatal("invalid config accepted")
			}
		})
	}
}
