package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

type redisQueue interface {
	Ping(context.Context) error
	Delete(context.Context, ...string) (int64, error)
	RPush(context.Context, string, string) (int64, error)
	LLen(context.Context, string) (int64, error)
	BLPop(context.Context, string, time.Duration) (string, bool, error)
}

type queuedMessage struct {
	ID         string `json:"id"`
	Sequence   int    `json:"sequence"`
	EnqueuedNS int64  `json:"enqueued_ns"`
}

func runProducer(ctx context.Context, cfg workloadConfig, queue redisQueue, sink eventSink, logger *slog.Logger, runID string) error {
	if err := queue.Ping(ctx); err != nil {
		return fmt.Errorf("ping Redis: %w", err)
	}
	if _, err := queue.Delete(ctx, cfg.QueueKey, cfg.CompletionKey); err != nil {
		return fmt.Errorf("clear E04 Redis lists: %w", err)
	}
	sampleIndex := 0
	emitQueueDepth := func(at time.Time, depth, completed int64, observer string) {
		sampleIndex++
		sink.Emit(event.QueueDepthSample, at, map[string]any{
			"queue_key":       cfg.QueueKey,
			"completion_key":  cfg.CompletionKey,
			"queue_depth":     depth,
			"completed_count": completed,
			"sample_index":    sampleIndex,
			"observer":        observer,
			"precision":       "redis-command-response",
		})
	}
	emitQueueDepth(time.Now().UTC(), 0, 0, "producer")

	period := time.Duration(float64(time.Second) / cfg.ArrivalRate)
	start := time.Now()
	for sequence := 1; sequence <= cfg.MessageCount; sequence++ {
		if sequence > 1 {
			target := start.Add(time.Duration(sequence-1) * period)
			if err := waitUntil(ctx, target); err != nil {
				return err
			}
		}
		enqueuedAt := time.Now().UTC()
		message := queuedMessage{
			ID:         fmt.Sprintf("%s-%04d", runID, sequence),
			Sequence:   sequence,
			EnqueuedNS: enqueuedAt.UnixNano(),
		}
		payload, err := json.Marshal(message)
		if err != nil {
			return fmt.Errorf("encode E04 message: %w", err)
		}
		depth, err := queue.RPush(ctx, cfg.QueueKey, string(payload))
		ackAt := time.Now().UTC()
		if err != nil {
			return fmt.Errorf("enqueue E04 message %s: %w", message.ID, err)
		}
		if sequence == 1 {
			sink.Emit(event.BusyPeriodStarted, enqueuedAt, map[string]any{
				"first_message_id": message.ID,
				"message_count":    cfg.MessageCount,
				"arrival_rate":     cfg.ArrivalRate,
				"queue_key":        cfg.QueueKey,
			})
		}
		sink.Emit(event.MessageEnqueued, enqueuedAt, map[string]any{
			"message_id":        message.ID,
			"sequence":          sequence,
			"message_count":     cfg.MessageCount,
			"configured_lambda": cfg.ArrivalRate,
			"queue_key":         cfg.QueueKey,
			"queue_depth":       depth,
			"redis_ack_time_ns": ackAt.UnixNano(),
			"precision":         "producer-before-rpush",
		})
		emitQueueDepth(ackAt, depth, 0, "producer")
	}

	completionCtx, cancel := context.WithTimeout(ctx, cfg.CompletionTimeout)
	defer cancel()
	ticker := time.NewTicker(cfg.QueueSampleInterval)
	defer ticker.Stop()
	for {
		depth, err := queue.LLen(completionCtx, cfg.QueueKey)
		if err != nil {
			return fmt.Errorf("sample E04 queue depth: %w", err)
		}
		completed, err := queue.LLen(completionCtx, cfg.CompletionKey)
		if err != nil {
			return fmt.Errorf("sample E04 completion count: %w", err)
		}
		observedAt := time.Now().UTC()
		emitQueueDepth(observedAt, depth, completed, "producer")
		if completed > int64(cfg.MessageCount) {
			return fmt.Errorf("completion list has %d entries, expected at most %d", completed, cfg.MessageCount)
		}
		if depth == 0 && completed == int64(cfg.MessageCount) {
			sink.Emit(event.BusyPeriodEnded, observedAt, map[string]any{
				"message_count":     cfg.MessageCount,
				"completed_count":   completed,
				"final_queue_depth": depth,
				"queue_key":         cfg.QueueKey,
				"completion_key":    cfg.CompletionKey,
				"precision":         "redis-command-response",
			})
			logger.Info("E04 producer completed", "messages", cfg.MessageCount, "queue_depth", depth, "completed", completed)
			return nil
		}
		select {
		case <-completionCtx.Done():
			return fmt.Errorf("wait for E04 completion: %w", completionCtx.Err())
		case <-ticker.C:
		}
	}
}

func waitUntil(ctx context.Context, target time.Time) error {
	delay := time.Until(target)
	if delay <= 0 {
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
