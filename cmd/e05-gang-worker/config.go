package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"time"
)

type workerConfig struct {
	Rank              int
	Members           int
	BarrierMinimum    int
	Namespace         string
	HeadlessService   string
	ListenAddress     string
	ServicePort       int
	DiscoveryInterval time.Duration
	RequestTimeout    time.Duration
	BarrierTimeout    time.Duration
	WorkDuration      time.Duration
	LeaderGrace       time.Duration
}

func configFromEnv() (workerConfig, error) {
	rank, err := requiredInt("E05_RANK")
	if err != nil {
		return workerConfig{}, err
	}
	members, err := requiredInt("E05_N")
	if err != nil {
		return workerConfig{}, err
	}
	barrierMinimum, err := requiredInt("E05_K")
	if err != nil {
		return workerConfig{}, err
	}
	servicePort, err := optionalInt("E05_SERVICE_PORT", 8080)
	if err != nil {
		return workerConfig{}, err
	}
	discoveryInterval, err := optionalDuration("E05_DISCOVERY_INTERVAL", 250*time.Millisecond)
	if err != nil {
		return workerConfig{}, err
	}
	requestTimeout, err := optionalDuration("E05_REQUEST_TIMEOUT", 2*time.Second)
	if err != nil {
		return workerConfig{}, err
	}
	barrierTimeout, err := optionalDuration("E05_BARRIER_TIMEOUT", 10*time.Minute)
	if err != nil {
		return workerConfig{}, err
	}
	workDuration, err := optionalDuration("E05_WORK_DURATION", 10*time.Second)
	if err != nil {
		return workerConfig{}, err
	}
	leaderGrace, err := optionalDuration("E05_LEADER_GRACE_DURATION", time.Minute)
	if err != nil {
		return workerConfig{}, err
	}
	cfg := workerConfig{
		Rank:              rank,
		Members:           members,
		BarrierMinimum:    barrierMinimum,
		Namespace:         env("POD_NAMESPACE", "default"),
		HeadlessService:   os.Getenv("E05_HEADLESS_SERVICE"),
		ListenAddress:     env("E05_LISTEN_ADDRESS", fmt.Sprintf(":%d", servicePort)),
		ServicePort:       servicePort,
		DiscoveryInterval: discoveryInterval,
		RequestTimeout:    requestTimeout,
		BarrierTimeout:    barrierTimeout,
		WorkDuration:      workDuration,
		LeaderGrace:       leaderGrace,
	}
	if err := cfg.validate(); err != nil {
		return workerConfig{}, err
	}
	return cfg, nil
}

func (c workerConfig) validate() error {
	switch {
	case c.Members < 1:
		return fmt.Errorf("E05_N must be positive")
	case c.Rank < 0 || c.Rank >= c.Members:
		return fmt.Errorf("E05_RANK must be in [0, E05_N)")
	case c.BarrierMinimum < 1 || c.BarrierMinimum > c.Members:
		return fmt.Errorf("E05_K must be in [1, E05_N]")
	case c.HeadlessService == "":
		return fmt.Errorf("E05_HEADLESS_SERVICE is required")
	case c.Namespace == "":
		return fmt.Errorf("POD_NAMESPACE is required")
	case c.ServicePort < 1 || c.ServicePort > 65535:
		return fmt.Errorf("E05_SERVICE_PORT must be in [1, 65535]")
	case c.DiscoveryInterval <= 0:
		return fmt.Errorf("E05_DISCOVERY_INTERVAL must be positive")
	case c.RequestTimeout <= 0:
		return fmt.Errorf("E05_REQUEST_TIMEOUT must be positive")
	case c.BarrierTimeout <= 0:
		return fmt.Errorf("E05_BARRIER_TIMEOUT must be positive")
	case c.WorkDuration <= 0:
		return fmt.Errorf("E05_WORK_DURATION must be positive")
	case c.LeaderGrace <= 0:
		return fmt.Errorf("E05_LEADER_GRACE_DURATION must be positive")
	}
	if _, port, err := net.SplitHostPort(c.ListenAddress); err != nil || port == "" {
		return fmt.Errorf("E05_LISTEN_ADDRESS must be a host:port address")
	}
	return nil
}

func (c workerConfig) serviceDNSName() string {
	return fmt.Sprintf("%s.%s.svc", c.HeadlessService, c.Namespace)
}

func requiredInt(key string) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return 0, fmt.Errorf("%s is required", key)
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", key)
	}
	return value, nil
}

func optionalInt(key string, fallback int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", key)
	}
	return value, nil
}

func optionalDuration(key string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	value, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be a Go duration: %w", key, err)
	}
	return value, nil
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
