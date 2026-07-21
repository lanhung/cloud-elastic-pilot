package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

type Client struct {
	baseURL string
	token   string
	http    *http.Client
}

func NewClient(baseURL, token string) *Client {
	return &Client{baseURL: baseURL, token: token, http: &http.Client{Timeout: 15 * time.Second}}
}

func (c *Client) SendBatch(ctx context.Context, events []event.Event) error {
	if len(events) == 0 {
		return nil
	}
	body, err := json.Marshal(struct {
		Events []event.Event `json:"events"`
	}{events})
	if err != nil {
		return err
	}
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/v1/events:batch", bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}
		resp, err := c.http.Do(req)
		if err == nil && resp.StatusCode >= 200 && resp.StatusCode < 300 {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			return nil
		}
		if err != nil {
			lastErr = err
		} else {
			payload, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
			lastErr = fmt.Errorf("ingester returned %s: %s", resp.Status, string(payload))
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(1<<attempt) * 200 * time.Millisecond):
		}
	}
	return fmt.Errorf("send event batch: %w", lastErr)
}

type Batcher struct {
	client    *Client
	queue     chan event.Event
	batchSize int
	interval  time.Duration
	logger    *slog.Logger
	wg        sync.WaitGroup
	closeOnce sync.Once
}

func NewBatcher(client *Client, queueSize, batchSize int, interval time.Duration, logger *slog.Logger) *Batcher {
	if queueSize <= 0 {
		queueSize = 4096
	}
	if batchSize <= 0 {
		batchSize = 100
	}
	if interval <= 0 {
		interval = 500 * time.Millisecond
	}
	return &Batcher{client: client, queue: make(chan event.Event, queueSize), batchSize: batchSize, interval: interval, logger: logger}
}

func (b *Batcher) Start(ctx context.Context) {
	b.wg.Add(1)
	go func() {
		defer b.wg.Done()
		ticker := time.NewTicker(b.interval)
		defer ticker.Stop()
		batch := make([]event.Event, 0, b.batchSize)
		flush := func() {
			if len(batch) == 0 {
				return
			}
			flushCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			if err := b.client.SendBatch(flushCtx, batch); err != nil {
				b.logger.Error("failed to send event batch", "error", err, "count", len(batch))
			}
			batch = batch[:0]
		}
		for {
			select {
			case <-ctx.Done():
				flush()
				return
			case e, ok := <-b.queue:
				if !ok {
					flush()
					return
				}
				batch = append(batch, e)
				if len(batch) >= b.batchSize {
					flush()
				}
			case <-ticker.C:
				flush()
			}
		}
	}()
}

func (b *Batcher) Emit(e event.Event) error {
	e.Normalize()
	if err := e.Validate(); err != nil {
		return fmt.Errorf("invalid event: %w", err)
	}
	select {
	case b.queue <- e:
		return nil
	default:
		return errors.New("event queue is full")
	}
}

func (b *Batcher) Close() {
	b.closeOnce.Do(func() { close(b.queue); b.wg.Wait() })
}
