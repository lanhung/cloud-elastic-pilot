package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/hooke-repro/hooke-ack/internal/ack"
	"github.com/hooke-repro/hooke-ack/internal/config"
	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/hooke-repro/hooke-ack/internal/observability"
	"github.com/hooke-repro/hooke-ack/internal/transport"
)

func main() {
	configPath := flag.String("config", "/etc/hooke/ack-adapter.yaml", "adapter configuration")
	stdin := flag.Bool("stdin", false, "read newline-delimited JSON from stdin")
	flag.Parse()
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	payload, err := os.ReadFile(*configPath)
	if err != nil {
		logger.Error("read config", "error", err)
		os.Exit(2)
	}
	var parserConfig ack.Config
	if err := yaml.Unmarshal(payload, &parserConfig); err != nil {
		logger.Error("parse config", "error", err)
		os.Exit(2)
	}
	if parserConfig.DefaultRunID == "" {
		parserConfig.DefaultRunID = config.String("HOOKE_ACTIVE_RUN_ID", "")
	}
	parser, err := ack.NewParser(parserConfig)
	if err != nil {
		logger.Error("parser configuration", "error", err)
		os.Exit(2)
	}
	client := transport.NewClient(config.String("HOOKE_INGESTER_URL", "http://hooke-ingester.hooke-system.svc:8080"), config.String("HOOKE_AUTH_TOKEN", ""))
	process := func(ctx context.Context, records []map[string]any) error {
		var events []event.Event
		for _, record := range records {
			parsed, err := parser.Parse(record)
			if err != nil {
				return err
			}
			events = append(events, parsed...)
		}
		return client.SendBatch(ctx, events)
	}
	if *stdin {
		scanner := bufio.NewScanner(os.Stdin)
		buffer := make([]byte, 0, 64*1024)
		scanner.Buffer(buffer, 4<<20)
		for scanner.Scan() {
			var record map[string]any
			if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
				logger.Error("invalid input record", "error", err)
				continue
			}
			if err := process(ctx, []map[string]any{record}); err != nil {
				logger.Error("process input record", "error", err)
			}
		}
		if err := scanner.Err(); err != nil {
			logger.Error("read stdin", "error", err)
			os.Exit(1)
		}
		return
	}
	mux := http.NewServeMux()
	observability.RegisterCommon(mux, func() bool { return true })
	mux.HandleFunc("/v1/ack-records", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		defer r.Body.Close()
		raw, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var records []map[string]any
		if len(raw) > 0 && raw[0] == '[' {
			err = json.Unmarshal(raw, &records)
		} else {
			var record map[string]any
			err = json.Unmarshal(raw, &record)
			records = []map[string]any{record}
		}
		if err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if err := process(r.Context(), records); err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	})
	server := &http.Server{Addr: config.String("HOOKE_ACK_ADAPTER_ADDR", ":8082"), Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server", "error", err)
			stop()
		}
	}()
	<-ctx.Done()
}
