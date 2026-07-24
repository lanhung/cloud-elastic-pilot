package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

type recordedApplicationEvent struct {
	eventType  string
	at         time.Time
	attributes map[string]any
}

type collectingSink struct {
	mu     sync.Mutex
	events []recordedApplicationEvent
	once   map[string]struct{}
}

func (s *collectingSink) Emit(eventType string, at time.Time, attributes map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, recordedApplicationEvent{eventType: eventType, at: at, attributes: attributes})
}

func (s *collectingSink) EmitOnce(key, eventType string, at time.Time, attributes map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.once == nil {
		s.once = map[string]struct{}{}
	}
	if _, exists := s.once[key]; exists {
		return
	}
	s.once[key] = struct{}{}
	s.events = append(s.events, recordedApplicationEvent{eventType: eventType, at: at, attributes: attributes})
}

func (s *collectingSink) count(eventType string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, item := range s.events {
		if item.eventType == eventType {
			count++
		}
	}
	return count
}

type immediatelyCompletedQueue struct {
	messages []queuedMessage
}

func (q *immediatelyCompletedQueue) Ping(context.Context) error { return nil }
func (q *immediatelyCompletedQueue) Delete(context.Context, ...string) (int64, error) {
	q.messages = nil
	return 2, nil
}
func (q *immediatelyCompletedQueue) RPush(_ context.Context, key, payload string) (int64, error) {
	if key == "queue" {
		message, err := decodeQueuedMessage(payload)
		if err != nil {
			return 0, err
		}
		q.messages = append(q.messages, message)
		return 1, nil
	}
	return int64(len(q.messages)), nil
}
func (q *immediatelyCompletedQueue) LLen(_ context.Context, key string) (int64, error) {
	if key == "completed" {
		return int64(len(q.messages)), nil
	}
	return 0, nil
}
func (q *immediatelyCompletedQueue) BLPop(context.Context, string, time.Duration) (string, bool, error) {
	return "", false, nil
}

func TestProducerEmitsExactMessageAndBusyPeriodEvents(t *testing.T) {
	cfg := workloadConfig{
		QueueKey:            "queue",
		CompletionKey:       "completed",
		MessageCount:        3,
		ArrivalRate:         10_000,
		QueueSampleInterval: time.Millisecond,
		CompletionTimeout:   time.Second,
	}
	queue := &immediatelyCompletedQueue{}
	sink := &collectingSink{}
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))

	if err := runProducer(context.Background(), cfg, queue, sink, logger, "run-1"); err != nil {
		t.Fatal(err)
	}
	if sink.count(event.MessageEnqueued) != 3 {
		t.Fatalf("MESSAGE_ENQUEUED count = %d, want 3", sink.count(event.MessageEnqueued))
	}
	if sink.count(event.BusyPeriodStarted) != 1 || sink.count(event.BusyPeriodEnded) != 1 {
		t.Fatalf("busy events: start=%d end=%d", sink.count(event.BusyPeriodStarted), sink.count(event.BusyPeriodEnded))
	}
	if sink.count(event.QueueDepthSample) < 5 {
		t.Fatalf("queue depth samples = %d, want initial, per-message, and final samples", sink.count(event.QueueDepthSample))
	}
	for index, message := range queue.messages {
		if message.ID != fmt.Sprintf("run-1-%04d", index+1) || message.Sequence != index+1 || message.EnqueuedNS <= 0 {
			t.Fatalf("message %d = %#v", index, message)
		}
		if index > 0 && message.EnqueuedNS < queue.messages[index-1].EnqueuedNS {
			t.Fatal("producer timestamps are not monotonic")
		}
	}
}

func TestApplicationEventRecorderLogsSourceIdentityAndOnce(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	cfg := hooke.Config{
		ClusterID: "cluster", RunID: "run", Namespace: "experiment",
		PodName: "producer-1", PodUID: "pod-uid", NodeName: "node",
		ContainerName: "producer", WorkloadKind: "Job", WorkloadName: "producer",
	}
	recorder := newApplicationEventRecorder(logger, nil, cfg)
	at := time.Date(2026, 7, 24, 2, 3, 4, 5, time.UTC)
	recorder.EmitOnce("busy", event.BusyPeriodStarted, at, map[string]any{"message_count": 3})
	recorder.EmitOnce("busy", event.BusyPeriodStarted, at.Add(time.Second), nil)
	recorder.Close()

	scanner := bufio.NewScanner(&output)
	if !scanner.Scan() {
		t.Fatal("no event log written")
	}
	var record struct {
		EventType    string         `json:"hooke_event_type"`
		SourceTimeNS int64          `json:"source_time_ns"`
		PodUID       string         `json:"pod_uid"`
		Attributes   map[string]any `json:"hooke_attributes"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if scanner.Scan() {
		t.Fatalf("once event was logged twice: %s", scanner.Text())
	}
	if record.EventType != event.BusyPeriodStarted || record.SourceTimeNS != at.UnixNano() || record.PodUID != "pod-uid" {
		t.Fatalf("unexpected event log: %#v", record)
	}
}

func TestDecodeQueuedMessageRejectsMissingIdentity(t *testing.T) {
	if _, err := decodeQueuedMessage(`{"sequence":1,"enqueued_ns":1}`); err == nil {
		t.Fatal("message without ID was accepted")
	}
}
