package hooke

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/internal/transport"
)

type Config struct {
	IngesterURL     string
	AuthToken       string
	ClusterID       string
	RunID           string
	Namespace       string
	PodName         string
	PodUID          string
	NodeName        string
	WorkloadKind    string
	WorkloadName    string
	WorkloadUID     string
	ContainerName   string
	SourceComponent string
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
	e := event.New(c.cfg.ClusterID, c.cfg.RunID, eventType, c.cfg.SourceComponent, time.Now().UTC())
	e.ClockType = event.ClockRealtime
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
	if _, loaded := c.once.LoadOrStore(key, struct{}{}); loaded {
		return nil
	}
	if err := c.Emit(ctx, eventType, attributes); err != nil {
		c.once.Delete(key)
		return err
	}
	return nil
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
