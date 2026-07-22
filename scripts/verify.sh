#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

echo "[1/7] shell syntax"
bash -n scripts/*.sh

echo "[2/7] Python hook tests"
python3 -m unittest discover -s scripts/tests -p 'test_*.py'

echo "[3/7] gofmt"
gofmt -w cmd internal sdk
if [[ -n "$(gofmt -l cmd internal sdk)" ]]; then
  echo "gofmt failed" >&2
  exit 1
fi

echo "[4/7] go mod tidy"
go mod tidy

echo "[5/7] go vet"
go vet ./...

echo "[6/7] unit tests"
go test ./...

echo "[7/7] build"
go build ./cmd/...

if command -v helm >/dev/null 2>&1; then
  helm lint deploy/helm/hooke
fi

echo "verification complete"
