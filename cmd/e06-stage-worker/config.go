package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

var stageNamePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

type stageConfig struct {
	StageName       string
	Variant         string
	WorkDuration    time.Duration
	Predecessors    []string
	DependencyProof string
}

func stageConfigFromEnv() (stageConfig, error) {
	duration, err := time.ParseDuration(env("E06_WORK_DURATION", "1s"))
	if err != nil {
		return stageConfig{}, fmt.Errorf("E06_WORK_DURATION must be a Go duration: %w", err)
	}
	var predecessors []string
	for _, value := range strings.Split(os.Getenv("E06_PREDECESSORS"), ",") {
		if value = strings.TrimSpace(value); value != "" {
			predecessors = append(predecessors, value)
		}
	}
	cfg := stageConfig{
		StageName:       os.Getenv("E06_STAGE_NAME"),
		Variant:         os.Getenv("E06_VARIANT"),
		WorkDuration:    duration,
		Predecessors:    predecessors,
		DependencyProof: os.Getenv("E06_DEPENDENCY_PROOF"),
	}
	if err := cfg.validate(); err != nil {
		return stageConfig{}, err
	}
	return cfg, nil
}

func (c stageConfig) validate() error {
	if !stageNamePattern.MatchString(c.StageName) {
		return fmt.Errorf("E06_STAGE_NAME must match %s", stageNamePattern)
	}
	switch c.Variant {
	case "baseline", "tuned", "warmup":
	default:
		return fmt.Errorf("E06_VARIANT must be baseline, tuned, or warmup")
	}
	if c.WorkDuration <= 0 || c.WorkDuration > time.Hour {
		return fmt.Errorf("E06_WORK_DURATION must be in (0, 1h]")
	}
	for _, predecessor := range c.Predecessors {
		if !stageNamePattern.MatchString(predecessor) {
			return fmt.Errorf("invalid predecessor %q", predecessor)
		}
		if predecessor == c.StageName {
			return fmt.Errorf("stage cannot depend on itself")
		}
	}
	if c.DependencyProof == "" {
		return fmt.Errorf("E06_DEPENDENCY_PROOF is required")
	}
	return nil
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
