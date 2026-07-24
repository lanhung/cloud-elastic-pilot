SHELL := /usr/bin/env bash
GO ?= go
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Version=$(VERSION) -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Commit=$(COMMIT) -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Date=$(DATE)
BINS := hooke-ingester hooke-controller hooke-node-agent hooke-correlator hooke-ack-adapter hooke-migrate hookectl smoke-app keda-redis-app

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

.PHONY: smoke-ack smoke-ack-check attribution-ack attribution-ack-check e01-images e01-images-push e01-ack e01-ack-check e02-ack e02-ack-check e03-images e03-images-push e03-ack e03-ack-check e04-image e04-image-push e04-ack e04-ack-check test-scripts
test-scripts:
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'

smoke-ack:
	./scripts/ack-first-smoke.sh --config $${CONFIG:-configs/smoke.env}

smoke-ack-check:
	./scripts/ack-first-smoke.sh --config $${CONFIG:-configs/smoke.env} --check-only

attribution-ack:
	./scripts/ack-attribution-pilot.sh --config $${CONFIG:-configs/attribution-pilot.env}

attribution-ack-check:
	./scripts/ack-attribution-pilot.sh --config $${CONFIG:-configs/attribution-pilot.env} --check-only

e01-images:
	./scripts/build-e01-images.sh --repository "$${IMAGE_REPOSITORY:-hooke/e01}" --small-padding-mib "$${SMALL_PADDING_MIB:-64}" --large-padding-mib "$${LARGE_PADDING_MIB:-512}"

e01-images-push:
	@test -n "$${IMAGE_REPOSITORY:-}" || { echo "IMAGE_REPOSITORY is required" >&2; exit 2; }
	./scripts/build-e01-images.sh --repository "$${IMAGE_REPOSITORY}" --small-padding-mib "$${SMALL_PADDING_MIB:-64}" --large-padding-mib "$${LARGE_PADDING_MIB:-512}" --push --metadata "$${IMAGE_METADATA:-dist/e01-images.env}"

e01-ack:
	./scripts/ack-four-layer-baseline.sh --config $${CONFIG:-configs/four-layer-baseline.env}

e01-ack-check:
	./scripts/ack-four-layer-baseline.sh --config $${CONFIG:-configs/four-layer-baseline.env} --check-only

e02-ack:
	./scripts/ack-node-warm-pool.sh --config $${CONFIG:-configs/node-warm-pool.env}

e02-ack-check:
	./scripts/ack-node-warm-pool.sh --config $${CONFIG:-configs/node-warm-pool.env} --check-only

e03-images:
	./scripts/build-e03-images.sh --repository "$${IMAGE_REPOSITORY:-hooke/e03}" --sizes-mib "$${SIZES_MIB:-100,500,1024}" --images-per-size 4

e03-images-push:
	@test -n "$${IMAGE_REPOSITORY:-}" || { echo "IMAGE_REPOSITORY is required" >&2; exit 2; }
	./scripts/build-e03-images.sh --repository "$${IMAGE_REPOSITORY}" --sizes-mib "$${SIZES_MIB:-100,500,1024}" --images-per-size 4 --push --metadata "$${IMAGE_METADATA:-dist/e03-images.env}"

e03-ack:
	./scripts/ack-image-cache-concurrency.sh --config $${CONFIG:-configs/image-cache-concurrency.env}

e03-ack-check:
	./scripts/ack-image-cache-concurrency.sh --config $${CONFIG:-configs/image-cache-concurrency.env} --check-only

e04-image:
	./scripts/build-e04-image.sh --repository "$${IMAGE_REPOSITORY:-hooke/e04}"

e04-image-push:
	@test -n "$${IMAGE_REPOSITORY:-}" || { echo "IMAGE_REPOSITORY is required" >&2; exit 2; }
	./scripts/build-e04-image.sh --repository "$${IMAGE_REPOSITORY}" --push --metadata "$${IMAGE_METADATA:-dist/e04-image.env}"

e04-ack:
	./scripts/ack-keda-scale-to-zero.sh --config $${CONFIG:-configs/keda-scale-to-zero.env}

e04-ack-check:
	./scripts/ack-keda-scale-to-zero.sh --config $${CONFIG:-configs/keda-scale-to-zero.env} --check-only
