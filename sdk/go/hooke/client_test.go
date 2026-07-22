package hooke

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

func TestEmitAtPreservesBoundaryAndClockCorrection(t *testing.T) {
	received := make(chan event.Event, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/events:batch" || r.Header.Get("Authorization") != "Bearer token" {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		var request struct {
			Events []event.Event `json:"events"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil || len(request.Events) != 1 {
			http.Error(w, "invalid body", http.StatusBadRequest)
			return
		}
		received <- request.Events[0]
		w.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	offset := int64(250_000)
	uncertainty := int64(50_000)
	client, err := New(Config{
		IngesterURL: server.URL, AuthToken: "token", ClusterID: "cluster", RunID: "run",
		PodUID: "pod", ContainerName: "app", SourceComponent: "application",
		ClockOffsetNS: &offset, ClockUncertaintyNS: &uncertainty,
	})
	if err != nil {
		t.Fatal(err)
	}
	at := time.Unix(1_700_000_000, 123_456_789).UTC()
	if err := client.EmitAt(context.Background(), event.ApplicationListening, at, map[string]any{"port": 8080}); err != nil {
		t.Fatal(err)
	}

	got := <-received
	if got.SourceTimeNS != at.UnixNano() || got.EventTimeNS != at.UnixNano()+offset {
		t.Fatalf("unexpected source/event time: %#v", got)
	}
	if got.ClockOffsetNS == nil || *got.ClockOffsetNS != offset || got.ClockUncertaintyNS == nil || *got.ClockUncertaintyNS != uncertainty {
		t.Fatalf("missing clock quality: %#v", got)
	}
	if got.PodUID != "pod" || got.ContainerName != "app" || got.EventType != event.ApplicationListening {
		t.Fatalf("missing event identity: %#v", got)
	}
}
