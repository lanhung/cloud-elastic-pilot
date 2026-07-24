package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/attribution"
	"github.com/hooke-repro/hooke-ack/internal/correlate"
	"github.com/hooke-repro/hooke-ack/internal/event"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		runCommand(os.Args[2:])
	case "calculate":
		calculateCommand(os.Args[2:])
	case "report":
		reportCommand(os.Args[2:])
	case "attribution":
		attributionCommand(os.Args[2:])
	case "events":
		eventsCommand(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `hookectl commands:
  hookectl run create --api URL --cluster ID --name NAME --slo-seconds 30
  hookectl run stop --api URL --run-id ID
  hookectl calculate --dsn DSN --run-id ID
  hookectl report --dsn DSN --run-id ID
  hookectl attribution --dsn DSN --run-id ID --window 10m
  hookectl events import --api URL --cluster ID --run-id ID --file events.ndjson
  hookectl events export --dsn DSN --run-id ID --file events.ndjson`)
}

func eventsCommand(args []string) {
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}
	switch args[0] {
	case "import":
		eventsImportCommand(args[1:])
	case "export":
		eventsExportCommand(args[1:])
	default:
		usage()
		os.Exit(2)
	}
}

func eventsImportCommand(args []string) {
	fs := flag.NewFlagSet("events import", flag.ExitOnError)
	api := fs.String("api", "http://127.0.0.1:8080", "ingester API")
	token := fs.String("token", "", "bearer token")
	clusterID := fs.String("cluster", "", "default cluster ID")
	runID := fs.String("run-id", "", "default run ID")
	path := fs.String("file", "-", "normalized NDJSON file or - for stdin")
	_ = fs.Parse(args)
	if *clusterID == "" || *runID == "" || *path == "" {
		fs.Usage()
		os.Exit(2)
	}
	var input io.Reader = os.Stdin
	var file *os.File
	if *path != "-" {
		var err error
		file, err = os.Open(*path)
		fatal(err)
		defer file.Close()
		input = file
	}
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64*1024), 4<<20)
	batch := make([]event.Event, 0, 500)
	send := func() {
		if len(batch) == 0 {
			return
		}
		requestJSON(http.MethodPost, *api+"/v1/events:batch", *token, map[string]any{"events": batch})
		batch = batch[:0]
	}
	line := 0
	for scanner.Scan() {
		line++
		if len(bytes.TrimSpace(scanner.Bytes())) == 0 {
			continue
		}
		var item event.Event
		if err := json.Unmarshal(scanner.Bytes(), &item); err != nil {
			fatal(fmt.Errorf("decode NDJSON line %d: %w", line, err))
		}
		if item.EventTimeNS <= 0 {
			fatal(fmt.Errorf("NDJSON line %d has no real event_time_ns", line))
		}
		if item.ClusterID == "" {
			item.ClusterID = *clusterID
		} else if item.ClusterID != *clusterID {
			fatal(fmt.Errorf("NDJSON line %d cluster_id %q does not match %q", line, item.ClusterID, *clusterID))
		}
		if item.RunID == "" {
			item.RunID = *runID
		} else if item.RunID != *runID {
			fatal(fmt.Errorf("NDJSON line %d run_id %q does not match %q", line, item.RunID, *runID))
		}
		item.Normalize()
		if err := item.Validate(); err != nil {
			fatal(fmt.Errorf("validate NDJSON line %d: %w", line, err))
		}
		batch = append(batch, item)
		if len(batch) == cap(batch) {
			send()
		}
	}
	fatal(scanner.Err())
	send()
}

func eventsExportCommand(args []string) {
	fs := flag.NewFlagSet("events export", flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("HOOKE_MYSQL_DSN"), "MySQL DSN")
	runID := fs.String("run-id", "", "run ID")
	path := fs.String("file", "-", "NDJSON output file or - for stdout")
	_ = fs.Parse(args)
	if *dsn == "" || *runID == "" || *path == "" {
		fs.Usage()
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	store, err := mysqlstore.Open(ctx, *dsn)
	fatal(err)
	defer store.Close()
	rows, err := store.ListEventsByRun(ctx, *runID)
	fatal(err)

	var output io.Writer = os.Stdout
	var file *os.File
	if *path != "-" {
		file, err = os.OpenFile(*path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		fatal(err)
		defer file.Close()
		output = file
	}
	writer := bufio.NewWriter(output)
	encoder := json.NewEncoder(writer)
	for _, row := range rows {
		fatal(encoder.Encode(row.Event))
	}
	fatal(writer.Flush())
}

func attributionCommand(args []string) {
	fs := flag.NewFlagSet("attribution", flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("HOOKE_MYSQL_DSN"), "MySQL DSN")
	runID := fs.String("run-id", "", "run ID")
	window := fs.Duration("window", 10*time.Minute, "fallback time attribution window")
	_ = fs.Parse(args)
	if *dsn == "" || *runID == "" || *window <= 0 {
		fs.Usage()
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	store, err := mysqlstore.Open(ctx, *dsn)
	fatal(err)
	defer store.Close()
	rows, err := store.ListEventsByRun(ctx, *runID)
	fatal(err)
	events := make([]event.Event, 0, len(rows))
	for _, row := range rows {
		events = append(events, row.Event)
	}
	printJSON(attribution.Analyze(events, *window))
}

func runCommand(args []string) {
	if len(args) < 1 {
		usage()
		os.Exit(2)
	}
	switch args[0] {
	case "create":
		fs := flag.NewFlagSet("run create", flag.ExitOnError)
		api := fs.String("api", "http://127.0.0.1:8080", "ingester API")
		token := fs.String("token", "", "bearer token")
		cluster := fs.String("cluster", "", "cluster ID")
		name := fs.String("name", "", "run name")
		slo := fs.Float64("slo-seconds", 30, "SLO in seconds")
		labelsJSON := fs.String("labels-json", "{}", "run labels as a JSON object")
		_ = fs.Parse(args[1:])
		if *cluster == "" || *name == "" {
			fs.Usage()
			os.Exit(2)
		}
		labels := map[string]any{}
		if err := json.Unmarshal([]byte(*labelsJSON), &labels); err != nil {
			fatal(fmt.Errorf("parse --labels-json: %w", err))
		}
		payload := map[string]any{"cluster_id": *cluster, "name": *name, "slo_seconds": *slo, "labels": labels}
		requestJSON(http.MethodPost, *api+"/v1/runs", *token, payload)
	case "stop":
		fs := flag.NewFlagSet("run stop", flag.ExitOnError)
		api := fs.String("api", "http://127.0.0.1:8080", "ingester API")
		token := fs.String("token", "", "bearer token")
		runID := fs.String("run-id", "", "run ID")
		_ = fs.Parse(args[1:])
		if *runID == "" {
			fs.Usage()
			os.Exit(2)
		}
		requestJSON(http.MethodPost, *api+"/v1/runs/"+*runID+"/stop", *token, nil)
	default:
		usage()
		os.Exit(2)
	}
}

func calculateCommand(args []string) {
	fs := flag.NewFlagSet("calculate", flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("HOOKE_MYSQL_DSN"), "MySQL DSN")
	runID := fs.String("run-id", "", "run ID")
	_ = fs.Parse(args)
	if *dsn == "" || *runID == "" {
		fs.Usage()
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	store, err := mysqlstore.Open(ctx, *dsn)
	fatal(err)
	defer store.Close()
	run, err := store.GetRun(ctx, *runID)
	fatal(err)
	summary, err := correlate.Execute(ctx, store, *runID, run.SLOSeconds)
	fatal(err)
	printJSON(summary)
}

func reportCommand(args []string) {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("HOOKE_MYSQL_DSN"), "MySQL DSN")
	runID := fs.String("run-id", "", "run ID")
	_ = fs.Parse(args)
	if *dsn == "" || *runID == "" {
		fs.Usage()
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	store, err := mysqlstore.Open(ctx, *dsn)
	fatal(err)
	defer store.Close()
	run, err := store.GetRun(ctx, *runID)
	fatal(err)
	metrics, err := store.ListMetrics(ctx, *runID)
	fatal(err)
	printJSON(map[string]any{"run": run, "metrics": metrics})
}

func requestJSON(method, url, token string, payload any) {
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		fatal(err)
		body = bytes.NewReader(encoded)
	}
	req, err := http.NewRequest(method, url, body)
	fatal(err)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	fatal(err)
	defer resp.Body.Close()
	response, err := io.ReadAll(resp.Body)
	fatal(err)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		fatal(fmt.Errorf("%s: %s", resp.Status, string(response)))
	}
	if len(response) > 0 {
		fmt.Print(string(response))
	}
}
func printJSON(value any) {
	payload, err := json.MarshalIndent(value, "", "  ")
	fatal(err)
	fmt.Println(string(payload))
}
func fatal(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
