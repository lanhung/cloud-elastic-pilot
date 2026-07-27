package transport

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"strings"

	"github.com/hooke-repro/hooke-ack/internal/event"
	"github.com/prometheus/client_golang/prometheus"
)

var (
	collectorSamplePercent = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "hooke_collector_sample_percent",
		Help: "Configured deterministic collector sample percentage.",
	})
	collectorSamplingEvents = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "hooke_collector_sampling_events_total",
		Help: "Collector events considered by the deterministic sampler.",
	}, []string{"decision"})
)

func init() {
	prometheus.MustRegister(collectorSamplePercent, collectorSamplingEvents)
}

type EventEmitter interface {
	Emit(event.Event) error
}

// SamplingEmitter applies one deterministic decision to every event belonging
// to the same Pod. This preserves complete Pod lifecycle traces in the sampled
// population instead of independently dropping individual lifecycle events.
type SamplingEmitter struct {
	next    EventEmitter
	percent int
}

func NewSamplingEmitter(next EventEmitter, percent int) (*SamplingEmitter, error) {
	if next == nil {
		return nil, fmt.Errorf("sampling emitter requires a downstream emitter")
	}
	if percent < 0 || percent > 100 {
		return nil, fmt.Errorf("sample percent must be in [0,100]")
	}
	collectorSamplePercent.Set(float64(percent))
	return &SamplingEmitter{next: next, percent: percent}, nil
}

func (s *SamplingEmitter) Emit(item event.Event) error {
	if deterministicSample(item, s.percent) {
		collectorSamplingEvents.WithLabelValues("kept").Inc()
		return s.next.Emit(item)
	}
	collectorSamplingEvents.WithLabelValues("sampled_out").Inc()
	return nil
}

func deterministicSample(item event.Event, percent int) bool {
	switch percent {
	case 0:
		return false
	case 100:
		return true
	}
	sum := sha256.Sum256([]byte(sampleIdentity(item)))
	bucket := binary.BigEndian.Uint64(sum[:8]) % 100
	return bucket < uint64(percent)
}

func sampleIdentity(item event.Event) string {
	scopeKind, scopeID := "event", strings.Join([]string{
		item.SourceComponent,
		item.SourceInstance,
		item.Namespace,
		item.EventType,
		item.ResourceVersion,
	}, "/")
	switch {
	case item.PodUID != "":
		scopeKind, scopeID = "pod", item.PodUID
	case item.WorkloadUID != "":
		scopeKind, scopeID = "workload", item.WorkloadUID
	case item.NodeUID != "":
		scopeKind, scopeID = "node", item.NodeUID
	}
	return strings.Join([]string{
		item.ClusterID,
		item.RunID,
		scopeKind,
		scopeID,
	}, "/")
}
