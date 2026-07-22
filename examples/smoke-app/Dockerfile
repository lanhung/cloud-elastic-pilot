# Build from repository root. E01_PADDING_MIB adds deterministic,
# incompressible bytes so the large variant represents real transfer volume.
# docker build -f examples/smoke-app/Dockerfile --build-arg E01_PADDING_MIB=0 .
FROM golang:1.23-bookworm@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown
ARG E01_PADDING_MIB=0
ARG E01_PADDING_SEED=e01/v1/development
ARG SOURCE_DATE_EPOCH=0
RUN CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags "-s -w -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Version=${VERSION} -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Commit=${COMMIT} -X github.com/hooke-repro/hooke-ack/internal/buildinfo.Date=${BUILD_DATE}" \
      -o /out/smoke-app ./cmd/smoke-app \
    && CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags "-s -w" -o /out/e01-image-padding ./tools/e01-image-padding \
    && /out/e01-image-padding --mib "${E01_PADDING_MIB}" --seed "${E01_PADDING_SEED}" --output /out/e01-padding.bin \
    && touch --date="@${SOURCE_DATE_EPOCH}" /out/smoke-app /out/e01-padding.bin

FROM gcr.io/distroless/static-debian12:nonroot@sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35
ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown
ARG E01_PADDING_MIB=0
ARG E01_PADDING_SEED=e01/v1/development
LABEL org.opencontainers.image.title="Cloud Elastic Pilot E01 smoke workload" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="gcr.io/distroless/static-debian12:nonroot" \
      org.opencontainers.image.base.digest="sha256:f5b485ea962d9bd1186b2f6b3a061191539b905b82ec395de78cbfae51f20e35" \
      hooke.io/go-build-base.digest="sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db" \
      hooke.io/e01-padding-mib="${E01_PADDING_MIB}" \
      hooke.io/e01-padding-seed="${E01_PADDING_SEED}"
COPY --from=build /out/smoke-app /smoke-app
COPY --from=build /out/e01-padding.bin /e01-padding.bin
USER nonroot:nonroot
ENTRYPOINT ["/smoke-app"]
