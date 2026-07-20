package main

import (
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
  hookectl attribution --dsn DSN --run-id ID --window 10m`)
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
		_ = fs.Parse(args[1:])
		if *cluster == "" || *name == "" {
			fs.Usage()
			os.Exit(2)
		}
		payload := map[string]any{"cluster_id": *cluster, "name": *name, "slo_seconds": *slo}
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
