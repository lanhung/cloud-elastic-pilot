package main

import (
	"context"
	_ "embed"
	"log/slog"
	"os"

	"github.com/hooke-repro/hooke-ack/internal/config"
	mysqlstore "github.com/hooke-repro/hooke-ack/internal/storage/mysql"
)

//go:embed schema.sql
var schema string

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx := context.Background()
	dsn, err := config.Required("HOOKE_MYSQL_DSN")
	if err != nil {
		logger.Error("configuration", "error", err)
		os.Exit(2)
	}
	store, err := mysqlstore.Open(ctx, dsn)
	if err != nil {
		logger.Error("open mysql", "error", err)
		os.Exit(1)
	}
	defer store.Close()
	if _, err := store.DB.ExecContext(ctx, schema); err != nil {
		logger.Error("apply schema", "error", err)
		os.Exit(1)
	}
	logger.Info("schema applied")
}
