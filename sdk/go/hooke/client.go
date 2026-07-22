package hooke

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/internal/transport"
)

type Config struct {
	IngesterURL        string
	AuthToken          string
	ClusterID          string
	RunID              string
	Namespace          string
	PodName            string
	PodUID             string
	NodeName           string
	WorkloadKind       string
	WorkloadName       string
	WorkloadUID        string
	ContainerName      string
	SourceComponent    string
	ClockOffsetNS      *int64
	ClockUncertaintyNS *int64
}

type Client struct {
	cfg       Config
	transport *transport.Client
	once      sync.Map
}

func ConfigFromEnv() Config {
	return Config{
		IngesterURL: env("HOOKE_INGESTER_URL", "http://hooke-ingester.hooke-system.svc:8080"),
		AuthToken:   os.Getenv("HOOKE_AUTH_TOKEN"), ClusterID: os.Getenv("HOOKE_CLUSTER_ID"), RunID: os.Getenv("HOOKE_RUN_ID"),
		Namespace: os.Getenv("POD_NAMESPACE"), PodName: os.Getenv("POD_NAME"), PodUID: os.Getenv("POD_UID"), NodeName: os.Getenv("NODE_NAME"),
		WorkloadKind: os.Getenv("HOOKE_WORKLOAD_KIND"), WorkloadName: os.Getenv("HOOKE_WORKLOAD_NAME"), WorkloadUID: os.Getenv("HOOKE_WORKLOAD_UID"),
		ContainerName: os.Getenv("HOOKE_CONTAINER_NAME"), SourceComponent: env("HOOKE_SOURCE_COMPONENT", "application"),
		ClockOffsetNS: optionalInt64("HOOKE_CLOCK_OFFSET_NS"), ClockUncertaintyNS: optionalInt64("HOOKE_CLOCK_UNCERTAINTY_NS"),
	}
}

func New(cfg Config) (*Client, error) {
	if cfg.IngesterURL == "" || cfg.ClusterID == "" || cfg.RunID == "" {
		return nil, fmt.Errorf("ingester_url, cluster_id and run_id are required")
	}
	if cfg.SourceComponent == "" {
		cfg.SourceComponent = "application"
	}
	return &Client{cfg: cfg, transport: transport.NewClient(cfg.IngesterURL, cfg.AuthToken)}, nil
}

func (c *Client) Emit(ctx context.Context, eventType string, attributes map[string]any) error {
	return c.EmitAt(ctx, eventType, time.Now().UTC(), attributes)
}

// EmitAt preserves the timestamp captured at the actual lifecycle boundary,
// even when transport is deliberately moved off the application hot path.
func (c *Client) EmitAt(ctx context.Context, eventType string, at time.Time, attributes map[string]any) error {
	e := event.New(c.cfg.ClusterID, c.cfg.RunID, eventType, c.cfg.SourceComponent, at)
	e.ClockType = event.ClockRealtime
	if c.cfg.ClockOffsetNS != nil {
		offset := *c.cfg.ClockOffsetNS
		e.ClockOffsetNS = &offset
		e.EventTimeNS = e.SourceTimeNS + offset
	}
	if c.cfg.ClockUncertaintyNS != nil {
		uncertainty := *c.cfg.ClockUncertaintyNS
		e.ClockUncertaintyNS = &uncertainty
	}
	e.Namespace = c.cfg.Namespace
	e.PodName = c.cfg.PodName
	e.PodUID = c.cfg.PodUID
	e.NodeName = c.cfg.NodeName
	e.WorkloadKind = c.cfg.WorkloadKind
	e.WorkloadName = c.cfg.WorkloadName
	e.WorkloadUID = c.cfg.WorkloadUID
	e.ContainerName = c.cfg.ContainerName
	e.Attributes = attributes
	return c.transport.SendBatch(ctx, []event.Event{e})
}

func (c *Client) EmitOnce(ctx context.Context, key, eventType string, attributes map[string]any) error {
	return c.EmitOnceAt(ctx, key, eventType, time.Now().UTC(), attributes)
}

func (c *Client) EmitOnceAt(ctx context.Context, key, eventType string, at time.Time, attributes map[string]any) error {
	if _, loaded := c.once.LoadOrStore(key, struct{}{}); loaded {
		return nil
	}
	if err := c.EmitAt(ctx, eventType, at, attributes); err != nil {
		c.once.Delete(key)
		return err
	}
	return nil
}

// EmitOnceAsync records the once-key synchronously, then performs network I/O
// in the background so readiness and request latency are not inflated by the
// telemetry path.
func (c *Client) EmitOnceAsync(key, eventType string, at time.Time, attributes map[string]any) {
	if _, loaded := c.once.LoadOrStore(key, struct{}{}); loaded {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := c.EmitAt(ctx, eventType, at, attributes); err != nil {
			c.once.Delete(key)
		}
	}()
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func optionalInt64(key string) *int64 {
	raw := os.Getenv(key)
	if raw == "" {
		return nil
	}
	value, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return nil
	}
	return &value
}
