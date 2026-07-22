package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

func String(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value
	}
	return fallback
}

func Required(key string) (string, error) {
	value := os.Getenv(key)
	if value == "" {
		return "", fmt.Errorf("required environment variable %s is empty", key)
	}
	return value, nil
}

func Bool(key string, fallback bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func Int(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

// OptionalInt64 preserves the difference between an explicitly measured zero
// and an unavailable value. It is used for clock offset/uncertainty samples.
func OptionalInt64(key string) (int64, bool) {
	value, ok := os.LookupEnv(key)
	if !ok || value == "" {
		return 0, false
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, false
	}
	return parsed, true
}

func Duration(key string, fallback time.Duration) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}
