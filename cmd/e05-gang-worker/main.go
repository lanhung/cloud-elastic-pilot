package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/buildinfo"
	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/sdk/go/hooke"
)

type identityResponse struct {
	Rank    int `json:"rank"`
	Members int `json:"members"`
	Minimum int `json:"minimum"`
}

type barrierClient struct {
	cfg        workerConfig
	httpClient *http.Client
	resolver   *net.Resolver
	recorder   *applicationEventRecorder
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := configFromEnv()
	if err != nil {
		logger.Error("configuration", "error", err)
		os.Exit(2)
	}
	hookeConfig := hooke.ConfigFromEnv()
	var sdkClient *hooke.Client
	if !boolEnv("HOOKE_SDK_DISABLED", true) {
		sdkClient, err = hooke.New(hookeConfig)
		if err != nil {
			logger.Error("hooke SDK", "error", err)
			os.Exit(2)
		}
	}
	recorder := newApplicationEventRecorder(logger, sdkClient, hookeConfig)
	defer recorder.Close()

	var coordinator *barrierCoordinator
	if cfg.Rank == 0 {
		coordinator, err = newBarrierCoordinator(cfg.Members, cfg.BarrierMinimum)
		if err != nil {
			logger.Error("barrier coordinator", "error", err)
			os.Exit(2)
		}
	}
	readinessObserved := make(chan struct{})
	var readinessOnce sync.Once
	var readinessObservedAt time.Time
	mux := newWorkerMux(cfg, coordinator, recorder, func(at time.Time) {
		readinessOnce.Do(func() {
			readinessObservedAt = at
			close(readinessObserved)
		})
	})
	server := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           mux,
		ReadHeaderTimeout: cfg.RequestTimeout,
	}
	listener, err := net.Listen("tcp", cfg.ListenAddress)
	if err != nil {
		logger.Error("listen", "error", err)
		os.Exit(1)
	}
	listeningAt := time.Now().UTC()
	recorder.EmitOnce("application-listening", event.ApplicationListening, listeningAt, commonAttributes(cfg, map[string]any{
		"address": listener.Addr().String(),
	}))
	logger.Info("E05 gang worker listening",
		"rank", cfg.Rank,
		"n", cfg.Members,
		"k", cfg.BarrierMinimum,
		"address", listener.Addr().String(),
		"service_dns", cfg.serviceDNSName(),
		"version", buildinfo.Version,
		"commit", buildinfo.Commit,
		"build_date", buildinfo.Date,
	)
	serverErrors := make(chan error, 1)
	go func() {
		if serveErr := server.Serve(listener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			serverErrors <- serveErr
		}
		close(serverErrors)
	}()

	barrierCtx, cancelBarrier := context.WithTimeout(ctx, cfg.BarrierTimeout)
	select {
	case <-readinessObserved:
		logger.Info("kubelet readiness probe observed",
			"rank", cfg.Rank,
			"observed_at", readinessObservedAt,
		)
	case <-barrierCtx.Done():
		cancelBarrier()
		logger.Error("wait for kubelet readiness probe", "rank", cfg.Rank, "error", barrierCtx.Err())
		shutdownServer(server)
		os.Exit(1)
	}
	barrier := barrierClient{
		cfg:        cfg,
		httpClient: &http.Client{Timeout: cfg.RequestTimeout},
		resolver:   net.DefaultResolver,
		recorder:   recorder,
	}
	snapshot, err := barrier.Wait(barrierCtx)
	cancelBarrier()
	if err != nil {
		logger.Error("wait for E05 barrier", "rank", cfg.Rank, "error", err)
		shutdownServer(server)
		os.Exit(1)
	}

	workStartedAt := time.Now().UTC()
	recorder.EmitOnce("useful-work-started", event.UsefulWorkStarted, workStartedAt, commonAttributes(cfg, map[string]any{
		"joined_count_at_release": snapshot.JoinedCount,
		"joined_ranks_at_release": snapshot.JoinedRanks,
		"leader_release_time_ns":  snapshot.ReleasedAtNS,
		"queue_admission_policy":  "whole-job",
		"barrier_policy":          "application-k-of-n",
	}))
	iterations, digest, workErr := runSyntheticWork(ctx, cfg.WorkDuration, cfg.Rank)
	workFinishedAt := time.Now().UTC()
	if workErr != nil {
		logger.Error("synthetic work", "rank", cfg.Rank, "error", workErr)
		shutdownServer(server)
		os.Exit(1)
	}
	recorder.EmitOnce("useful-work-finished", event.UsefulWorkFinished, workFinishedAt, commonAttributes(cfg, map[string]any{
		"duration_ns": workFinishedAt.Sub(workStartedAt).Nanoseconds(),
		"iterations":  iterations,
		"digest":      digest,
	}))

	if coordinator != nil {
		select {
		case <-coordinator.AllJoined():
			logger.Info("all E05 members joined", "joined", cfg.Members)
		case <-time.After(cfg.LeaderGrace):
			logger.Warn("leader grace expired before all members joined",
				"snapshot", coordinator.Snapshot(),
				"leader_grace", cfg.LeaderGrace,
			)
		case <-ctx.Done():
		}
	}
	shutdownServer(server)
	if serveErr := <-serverErrors; serveErr != nil {
		logger.Error("HTTP server", "error", serveErr)
		os.Exit(1)
	}
}

func newWorkerMux(
	cfg workerConfig,
	coordinator *barrierCoordinator,
	recorder *applicationEventRecorder,
	readinessObserved func(time.Time),
) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/identity", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, identityResponse{Rank: cfg.Rank, Members: cfg.Members, Minimum: cfg.BarrierMinimum})
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		at := time.Now().UTC()
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rank": cfg.Rank})
		recorder.EmitOnce("readiness-first-success", event.ReadinessProbeFirstSuccess, at, commonAttributes(cfg, map[string]any{
			"path":   r.URL.Path,
			"status": http.StatusOK,
		}))
		readinessObserved(at)
	})
	mux.HandleFunc("/join", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST required"})
			return
		}
		if coordinator == nil {
			writeJSON(w, http.StatusConflict, map[string]any{"error": "not the rank-0 coordinator"})
			return
		}
		rank, err := strconv.Atoi(r.URL.Query().Get("rank"))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "rank must be an integer"})
			return
		}
		snapshot, _, err := coordinator.Join(rank, time.Now().UTC())
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, snapshot)
	})
	return mux
}

func (c *barrierClient) Wait(ctx context.Context) (barrierSnapshot, error) {
	var leaderURL string
	var enteredAt time.Time
	for {
		if err := ctx.Err(); err != nil {
			return barrierSnapshot{}, fmt.Errorf("barrier deadline: %w", err)
		}
		if leaderURL == "" {
			resolved, err := c.findLeader(ctx)
			if err != nil {
				if err := waitInterval(ctx, c.cfg.DiscoveryInterval); err != nil {
					return barrierSnapshot{}, fmt.Errorf("discover rank-0 leader: %w", err)
				}
				continue
			}
			leaderURL = resolved
		}
		snapshot, err := c.join(ctx, leaderURL)
		if err != nil {
			leaderURL = ""
			if err := waitInterval(ctx, c.cfg.DiscoveryInterval); err != nil {
				return barrierSnapshot{}, fmt.Errorf("join rank-0 leader: %w", err)
			}
			continue
		}
		if enteredAt.IsZero() {
			enteredAt = time.Now().UTC()
			c.recorder.EmitOnce("gang-barrier-enter", event.GangBarrierEnter, enteredAt, commonAttributes(c.cfg, map[string]any{
				"joined_count":           snapshot.JoinedCount,
				"joined_ranks":           snapshot.JoinedRanks,
				"readiness_gate":         "kubelet-probe-observed",
				"queue_admission_policy": "whole-job",
				"barrier_policy":         "application-k-of-n",
			}))
		}
		if snapshot.Released {
			exitedAt := time.Now().UTC()
			c.recorder.EmitOnce("gang-barrier-exit", event.GangBarrierExit, exitedAt, commonAttributes(c.cfg, map[string]any{
				"joined_count":           snapshot.JoinedCount,
				"joined_ranks":           snapshot.JoinedRanks,
				"leader_release_time_ns": snapshot.ReleasedAtNS,
				"barrier_wait_ns":        exitedAt.Sub(enteredAt).Nanoseconds(),
				"barrier_policy":         "application-k-of-n",
			}))
			return snapshot, nil
		}
		if err := waitInterval(ctx, c.cfg.DiscoveryInterval); err != nil {
			return barrierSnapshot{}, fmt.Errorf("wait for barrier release: %w", err)
		}
	}
}

func (c *barrierClient) findLeader(ctx context.Context) (string, error) {
	if c.cfg.Rank == 0 {
		return fmt.Sprintf("http://%s", net.JoinHostPort("127.0.0.1", strconv.Itoa(c.cfg.ServicePort))), nil
	}
	addresses, err := c.resolver.LookupHost(ctx, c.cfg.serviceDNSName())
	if err != nil {
		return "", err
	}
	sort.Strings(addresses)
	var failures []string
	for _, address := range addresses {
		baseURL := fmt.Sprintf("http://%s", net.JoinHostPort(address, strconv.Itoa(c.cfg.ServicePort)))
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/identity", nil)
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		response, err := c.httpClient.Do(request)
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		var identity identityResponse
		decodeErr := decodeResponse(response, &identity)
		if decodeErr == nil && identity.Rank == 0 &&
			identity.Members == c.cfg.Members &&
			identity.Minimum == c.cfg.BarrierMinimum {
			return baseURL, nil
		}
		if decodeErr != nil {
			failures = append(failures, decodeErr.Error())
		}
	}
	return "", fmt.Errorf("rank-0 leader not found among %d endpoint(s): %v", len(addresses), failures)
}

func (c *barrierClient) join(ctx context.Context, leaderURL string) (barrierSnapshot, error) {
	url := fmt.Sprintf("%s/join?rank=%d", leaderURL, c.cfg.Rank)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(nil))
	if err != nil {
		return barrierSnapshot{}, err
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return barrierSnapshot{}, err
	}
	var snapshot barrierSnapshot
	if err := decodeResponse(response, &snapshot); err != nil {
		return barrierSnapshot{}, err
	}
	if snapshot.Members != c.cfg.Members || snapshot.Minimum != c.cfg.BarrierMinimum {
		return barrierSnapshot{}, fmt.Errorf(
			"coordinator dimensions changed: got n=%d k=%d, want n=%d k=%d",
			snapshot.Members, snapshot.Minimum, c.cfg.Members, c.cfg.BarrierMinimum,
		)
	}
	return snapshot, nil
}

func decodeResponse(response *http.Response, target any) error {
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d: %s", response.StatusCode, string(body))
	}
	if err := json.Unmarshal(body, target); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func commonAttributes(cfg workerConfig, extra map[string]any) map[string]any {
	attributes := map[string]any{
		"rank":              cfg.Rank,
		"n":                 cfg.Members,
		"k":                 cfg.BarrierMinimum,
		"coordinator_rank":  0,
		"admission_members": cfg.Members,
	}
	for key, value := range extra {
		attributes[key] = value
	}
	return attributes
}

func waitInterval(ctx context.Context, interval time.Duration) error {
	timer := time.NewTimer(interval)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func runSyntheticWork(ctx context.Context, duration time.Duration, rank int) (uint64, string, error) {
	deadline := time.Now().Add(duration)
	block := make([]byte, 64*1024)
	block[0] = byte(rank)
	digest := sha256.Sum256(block)
	var iterations uint64
	for time.Now().Before(deadline) {
		copy(block, digest[:])
		block[len(block)-1] = byte(iterations)
		digest = sha256.Sum256(block)
		iterations++
		if iterations%128 == 0 {
			select {
			case <-ctx.Done():
				return iterations, hex.EncodeToString(digest[:]), ctx.Err()
			default:
			}
		}
	}
	return iterations, hex.EncodeToString(digest[:]), nil
}

func shutdownServer(server *http.Server) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
}
