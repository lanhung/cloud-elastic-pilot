# Build from repository root:
# docker build -f examples/smoke-app/Dockerfile .
FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/smoke-app ./cmd/smoke-app
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/smoke-app /smoke-app
USER nonroot:nonroot
ENTRYPOINT ["/smoke-app"]
