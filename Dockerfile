# syntax=docker/dockerfile:1.7
FROM golang:1.23-bookworm AS build
ARG VERSION=dev
ARG COMMIT=none
ARG DATE=unknown
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN set -eux; \
    mkdir -p /out; \
    for bin in hooke-ingester hooke-controller hooke-node-agent hooke-correlator hooke-ack-adapter hooke-migrate hookectl smoke-app; do \
      CGO_ENABLED=0 GOOS=linux go build -trimpath \
        -ldflags "-s -w -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Version=${VERSION} -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Commit=${COMMIT} -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Date=${DATE}" \
        -o /out/${bin} ./cmd/${bin}; \
    done

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ /
USER nonroot:nonroot
CMD ["/hooke-ingester"]
