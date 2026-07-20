SHELL := /usr/bin/env bash
GO ?= go
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Version=$(VERSION) -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Commit=$(COMMIT) -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Date=$(DATE)
BINS := hooke-ingester hooke-controller hooke-node-agent hooke-correlator hooke-ack-adapter hooke-migrate hookectl smoke-app

.PHONY: all fmt vet test test-race build tidy lint clean db-up db-down smoke-package verify

all: fmt vet test build

fmt:
	@files="$$(gofmt -l .)"; if [[ -n "$$files" ]]; then echo "gofmt required:"; echo "$$files"; exit 1; fi

vet:
	$(GO) vet ./...

test:
	$(GO) test ./... -coverprofile=coverage.out

test-race:
	$(GO) test -race ./...

build:
	@mkdir -p bin
	@for bin in $(BINS); do \
		$(GO) build -trimpath -ldflags '$(LDFLAGS)' -o bin/$$bin ./cmd/$$bin; \
	done

tidy:
	$(GO) mod tidy

lint:
	golangci-lint run ./...

clean:
	rm -rf bin dist coverage.out

db-up:
	docker compose -f deploy/compose/docker-compose.yaml up -d mysql

db-down:
	docker compose -f deploy/compose/docker-compose.yaml down -v

verify:
	./scripts/verify.sh

.PHONY: smoke-ack smoke-ack-check attribution-ack attribution-ack-check
smoke-ack:
	./scripts/ack-first-smoke.sh --config $${CONFIG:-configs/smoke.env}

smoke-ack-check:
	./scripts/ack-first-smoke.sh --config $${CONFIG:-configs/smoke.env} --check-only

attribution-ack:
	./scripts/ack-attribution-pilot.sh --config $${CONFIG:-configs/attribution-pilot.env}

attribution-ack-check:
	./scripts/ack-attribution-pilot.sh --config $${CONFIG:-configs/attribution-pilot.env} --check-only
