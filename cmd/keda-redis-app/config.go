package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type workloadConfig struct {
	Mode                string
	RedisAddress        string
	RedisPassword       string
	QueueKey            string
	CompletionKey       string
	MessageCount        int
	ArrivalRate         float64
	ProcessingDuration  time.Duration
	QueueSampleInterval time.Duration
	CompletionTimeout   time.Duration
	BLPopTimeout        time.Duration
	HTTPAddress         string
}

func configFromEnv() (workloadConfig, error) {
	cfg := workloadConfig{
		Mode:                strings.ToLower(envString("E04_MODE", "worker")),
		RedisAddress:        envString("E04_REDIS_ADDRESS", "redis:6379"),
		RedisPassword:       os.Getenv("E04_REDIS_PASSWORD"),
		QueueKey:            envString("E04_QUEUE_KEY", "hooke:e04:queue"),
		CompletionKey:       envString("E04_COMPLETION_KEY", "hooke:e04:completed"),
		MessageCount:        12,
		ArrivalRate:         1,
		ProcessingDuration:  2 * time.Second,
		QueueSampleInterval: time.Second,
		CompletionTimeout:   10 * time.Minute,
		BLPopTimeout:        time.Second,
		HTTPAddress:         envString("E04_HTTP_ADDR", ":8080"),
	}
	var err error
	if cfg.MessageCount, err = envPositiveInt("E04_MESSAGE_COUNT", cfg.MessageCount); err != nil {
		return workloadConfig{}, err
	}
	if cfg.ArrivalRate, err = envPositiveFloat("E04_ARRIVAL_RATE", cfg.ArrivalRate); err != nil {
		return workloadConfig{}, err
	}
	if cfg.ProcessingDuration, err = envNonNegativeDuration("E04_PROCESSING_DURATION", cfg.ProcessingDuration); err != nil {
		return workloadConfig{}, err
	}
	if cfg.QueueSampleInterval, err = envPositiveDuration("E04_QUEUE_SAMPLE_INTERVAL", cfg.QueueSampleInterval); err != nil {
		return workloadConfig{}, err
	}
	if cfg.CompletionTimeout, err = envPositiveDuration("E04_COMPLETION_TIMEOUT", cfg.CompletionTimeout); err != nil {
		return workloadConfig{}, err
	}
	if cfg.BLPopTimeout, err = envPositiveDuration("E04_BLPOP_TIMEOUT", cfg.BLPopTimeout); err != nil {
		return workloadConfig{}, err
	}
	if cfg.Mode != "worker" && cfg.Mode != "producer" {
		return workloadConfig{}, fmt.Errorf("E04_MODE must be worker or producer, got %q", cfg.Mode)
	}
	if strings.TrimSpace(cfg.RedisAddress) == "" || strings.TrimSpace(cfg.QueueKey) == "" || strings.TrimSpace(cfg.CompletionKey) == "" {
		return workloadConfig{}, fmt.Errorf("Redis address, queue key, and completion key must be non-empty")
	}
	if cfg.QueueKey == cfg.CompletionKey {
		return workloadConfig{}, fmt.Errorf("E04_QUEUE_KEY and E04_COMPLETION_KEY must differ")
	}
	if cfg.ArrivalRate > 10_000 {
		return workloadConfig{}, fmt.Errorf("E04_ARRIVAL_RATE cannot exceed 10000")
	}
	return cfg, nil
}

func envString(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envPositiveInt(key string, fallback int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", key)
	}
	return value, nil
}

func envPositiveFloat(key string, fallback float64) (float64, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("%s must be a positive number", key)
	}
	return value, nil
}

func envPositiveDuration(key string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration", key)
	}
	return value, nil
}

func envNonNegativeDuration(key string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil || value < 0 {
		return 0, fmt.Errorf("%s must be a non-negative duration", key)
	}
	return value, nil
}

func envBool(key string, fallback bool) bool {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback
	}
	value, err := strconv.ParseBool(raw)
	if err != nil {
		return fallback
	}
	return value
}
