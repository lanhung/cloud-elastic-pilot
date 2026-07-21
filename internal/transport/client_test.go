package transport

import (
	"strings"
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

func TestBatcherEmitRejectsInvalidEventBeforeBatching(t *testing.T) {
	batcher := NewBatcher(nil, 1, 1, time.Second, nil)
	item := event.New("cluster", "run", event.PodCreated, "test", time.Now())
	item.EventTimeNS = -1

	err := batcher.Emit(item)
	if err == nil || !strings.Contains(err.Error(), "event_time_ns must be positive") {
		t.Fatalf("Emit() error = %v, want invalid timestamp", err)
	}
	if len(batcher.queue) != 0 {
		t.Fatalf("invalid event entered queue; length = %d", len(batcher.queue))
	}
}

func TestBatcherEmitNormalizesZeroTimestamp(t *testing.T) {
	batcher := NewBatcher(nil, 1, 1, time.Second, nil)
	item := event.New("cluster", "run", event.PodCreated, "test", time.Now())
	item.EventTimeNS = 0

	if err := batcher.Emit(item); err != nil {
		t.Fatalf("Emit() error = %v", err)
	}
	queued := <-batcher.queue
	if queued.EventTimeNS <= 0 {
		t.Fatalf("queued event time = %d, want positive", queued.EventTimeNS)
	}
}
