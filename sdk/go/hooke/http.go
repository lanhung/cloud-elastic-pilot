package hooke

import (
	"net/http"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

func (c *Client) ReadinessHandler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		if recorder.status >= 200 && recorder.status < 400 {
			c.EmitOnceAsync("readiness-first-success", event.ReadinessProbeFirstSuccess, time.Now().UTC(), map[string]any{"path": r.URL.Path, "status": recorder.status})
		}
	})
}

func (c *Client) FirstRequestMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		c.EmitOnceAsync("first-request", event.FirstRequestReceived, start.UTC(), map[string]any{"method": r.Method, "path": r.URL.Path})
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		if recorder.status >= 200 && recorder.status < 400 {
			c.EmitOnceAsync("first-success", event.FirstSuccessfulResponse, time.Now().UTC(), map[string]any{"method": r.Method, "path": r.URL.Path, "status": recorder.status, "duration_ms": float64(time.Since(start).Microseconds()) / 1000})
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) { s.status = code; s.ResponseWriter.WriteHeader(code) }
