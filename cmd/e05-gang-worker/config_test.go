package main

import (
	"testing"
	"time"
)

func TestWorkerConfigValidation(t *testing.T) {
	valid := workerConfig{
		Rank:              1,
		Members:           4,
		BarrierMinimum:    2,
		Namespace:         "e05-run",
		HeadlessService:   "gang",
		ListenAddress:     ":8080",
		ServicePort:       8080,
		DiscoveryInterval: time.Millisecond,
		RequestTimeout:    time.Second,
		BarrierTimeout:    time.Minute,
		WorkDuration:      time.Second,
		LeaderGrace:       time.Second,
	}
	if err := valid.validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	tests := []struct {
		name   string
		mutate func(*workerConfig)
	}{
		{name: "rank", mutate: func(cfg *workerConfig) { cfg.Rank = cfg.Members }},
		{name: "n", mutate: func(cfg *workerConfig) { cfg.Members = 0 }},
		{name: "k-zero", mutate: func(cfg *workerConfig) { cfg.BarrierMinimum = 0 }},
		{name: "k-large", mutate: func(cfg *workerConfig) { cfg.BarrierMinimum = cfg.Members + 1 }},
		{name: "service", mutate: func(cfg *workerConfig) { cfg.HeadlessService = "" }},
		{name: "listen", mutate: func(cfg *workerConfig) { cfg.ListenAddress = "8080" }},
		{name: "timeout", mutate: func(cfg *workerConfig) { cfg.BarrierTimeout = 0 }},
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
