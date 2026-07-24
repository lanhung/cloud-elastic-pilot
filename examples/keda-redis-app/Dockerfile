# Build from the repository root.
FROM golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown
ARG SOURCE_DATE_EPOCH=0
RUN CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Version=${VERSION} -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Commit=${COMMIT} -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Date=${BUILD_DATE}" \
      -o /out/keda-redis-app ./cmd/keda-redis-app \
    && touch --date="@${SOURCE_DATE_EPOCH}" /out/keda-redis-app

FROM gcr.io/distroless/static-debian12:nonroot@sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="Cloud Elastic Pilot E04 Redis workload" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="gcr.io/distroless/static-debian12:nonroot" \
      org.opencontainers.image.base.digest="sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35" \
      hooke.io/go-build-base.digest="sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db"
COPY --from=build /out/keda-redis-app /keda-redis-app
USER nonroot:nonroot
ENTRYPOINT ["/keda-redis-app"]
