#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

echo "[1/5] gofmt"
gofmt -w cmd internal sdk
if [[ -n "$(gofmt -l cmd internal sdk)" ]]; then
  echo "gofmt failed" >&2
  exit 1
fi

echo "[2/5] go mod tidy"
go mod tidy

echo "[3/5] go vet"
go vet ./...

echo "[4/5] unit tests"
go test ./...

echo "[5/5] build"
go build ./cmd/...

if command -v helm >/dev/null 2>&1; then
  helm lint deploy/helm/hooke
fi

echo "verification complete"
