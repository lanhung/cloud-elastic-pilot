package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

func runWorker(ctx context.Context, cfg workloadConfig, queue redisQueue, sink eventSink, logger *slog.Logger) error {
	if err := waitForRedis(ctx, queue); err != nil {
		return err
	}
	serverErrors := make(chan error, 1)
	server, err := startReadinessServer(ctx, cfg.HTTPAddress, sink, logger, serverErrors)
	if err != nil {
		return err
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	sampleIndex := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-serverErrors:
			return err
		default:
		}
		popCtx, cancel := context.WithTimeout(ctx, cfg.BLPopTimeout+2*time.Second)
		payload, found, err := queue.BLPop(popCtx, cfg.QueueKey, cfg.BLPopTimeout)
		cancel()
		if err != nil {
			if errors.Is(err, context.Canceled) && ctx.Err() != nil {
				return ctx.Err()
			}
			return fmt.Errorf("dequeue E04 message: %w", err)
		}
		if !found {
			continue
		}
		message, err := decodeQueuedMessage(payload)
		if err != nil {
			return err
		}
		dequeuedAt := time.Now().UTC()
		common := map[string]any{
			"message_id":  message.ID,
			"sequence":    message.Sequence,
			"queue_key":   cfg.QueueKey,
			"enqueued_ns": message.EnqueuedNS,
		}
		sink.Emit(event.MessageDequeued, dequeuedAt, mergeEventAttributes(common, map[string]any{
			"queue_latency_ms": float64(dequeuedAt.UnixNano()-message.EnqueuedNS) / 1e6,
			"precision":        "redis-blpop-response",
		}))
		sink.Emit(event.MessageProcessingStarted, dequeuedAt, mergeEventAttributes(common, map[string]any{
			"processing_duration_ms": float64(cfg.ProcessingDuration.Microseconds()) / 1000,
		}))
		if err := waitDuration(ctx, cfg.ProcessingDuration); err != nil {
			return err
		}
		processedAt := time.Now().UTC()
		completion := map[string]any{
			"message_id":   message.ID,
			"sequence":     message.Sequence,
			"processed_ns": processedAt.UnixNano(),
		}
		completionPayload, err := json.Marshal(completion)
		if err != nil {
			return fmt.Errorf("encode E04 completion: %w", err)
		}
		completedCount, err := queue.RPush(ctx, cfg.CompletionKey, string(completionPayload))
		ackAt := time.Now().UTC()
		if err != nil {
			return fmt.Errorf("record E04 completion for %s: %w", message.ID, err)
		}
		sink.Emit(event.MessageProcessed, processedAt, mergeEventAttributes(common, map[string]any{
			"completed_count":        completedCount,
			"completion_key":         cfg.CompletionKey,
			"completion_ack_time_ns": ackAt.UnixNano(),
			"processing_latency_ms":  float64(processedAt.Sub(dequeuedAt).Microseconds()) / 1000,
			"end_to_end_latency_ms":  float64(processedAt.UnixNano()-message.EnqueuedNS) / 1e6,
			"precision":              "worker-before-completion-rpush",
		}))
		depth, err := queue.LLen(ctx, cfg.QueueKey)
		if err != nil {
			return fmt.Errorf("sample worker queue depth: %w", err)
		}
		sampleIndex++
		sink.Emit(event.QueueDepthSample, time.Now().UTC(), map[string]any{
			"queue_key":       cfg.QueueKey,
			"completion_key":  cfg.CompletionKey,
			"queue_depth":     depth,
			"completed_count": completedCount,
			"sample_index":    sampleIndex,
			"observer":        "worker",
			"precision":       "redis-command-response",
		})
	}
}

func waitForRedis(ctx context.Context, queue redisQueue) error {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err := queue.Ping(pingCtx)
		cancel()
		if err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func startReadinessServer(ctx context.Context, address string, sink eventSink, logger *slog.Logger, errorCh chan<- error) (*http.Server, error) {
	mux := http.NewServeMux()
	mux.HandleFunc("/readyz", func(writer http.ResponseWriter, request *http.Request) {
		at := time.Now().UTC()
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("ok"))
		sink.EmitOnce("readiness-first-success", event.ReadinessProbeFirstSuccess, at, map[string]any{
			"path": request.URL.Path, "status": http.StatusOK,
		})
	})
	server := &http.Server{
		Addr:              address,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, fmt.Errorf("listen for readiness: %w", err)
	}
	listeningAt := time.Now().UTC()
	sink.EmitOnce("application-listening", event.ApplicationListening, listeningAt, map[string]any{
		"address": listener.Addr().String(),
	})
	logger.Info("E04 worker ready", "address", listener.Addr().String())
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			select {
			case errorCh <- fmt.Errorf("serve readiness: %w", err):
			case <-ctx.Done():
			}
		}
	}()
	return server, nil
}

func decodeQueuedMessage(payload string) (queuedMessage, error) {
	var message queuedMessage
	if err := json.Unmarshal([]byte(payload), &message); err != nil {
		return queuedMessage{}, fmt.Errorf("decode E04 message: %w", err)
	}
	if message.ID == "" || message.Sequence <= 0 || message.EnqueuedNS <= 0 {
		return queuedMessage{}, fmt.Errorf("invalid E04 message: %#v", message)
	}
	return message, nil
}

func mergeEventAttributes(base, extra map[string]any) map[string]any {
	merged := make(map[string]any, len(base)+len(extra))
	for key, value := range base {
		merged[key] = value
	}
	for key, value := range extra {
		merged[key] = value
	}
	return merged
}

func waitDuration(ctx context.Context, duration time.Duration) error {
	if duration <= 0 {
		return nil
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
