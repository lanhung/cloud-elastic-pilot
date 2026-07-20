package elasticity

import (
	"errors"
	"math"
	"sort"
)

func LayerScore(latencySeconds []float64, sloSeconds float64) (float64, error) {
	if sloSeconds <= 0 {
		return 0, errors.New("sloSeconds must be positive")
	}
	if len(latencySeconds) == 0 {
		return 0, errors.New("at least one sample is required")
	}
	var sum float64
	for _, latency := range latencySeconds {
		if latency < 0 {
			return 0, errors.New("latency cannot be negative")
		}
		sum += math.Exp(-latency / sloSeconds)
	}
	return sum / float64(len(latencySeconds)), nil
}

func Product(values ...float64) float64 {
	result := 1.0
	for _, v := range values {
		result *= v
	}
	return result
}

func Percentile(values []float64, p float64) (float64, error) {
	if len(values) == 0 {
		return 0, errors.New("no values")
	}
	if p < 0 || p > 1 {
		return 0, errors.New("p must be in [0,1]")
	}
	copyValues := append([]float64(nil), values...)
	sort.Float64s(copyValues)
	if len(copyValues) == 1 {
		return copyValues[0], nil
	}
	pos := p * float64(len(copyValues)-1)
	low := int(math.Floor(pos))
	high := int(math.Ceil(pos))
	if low == high {
		return copyValues[low], nil
	}
	weight := pos - float64(low)
	return copyValues[low]*(1-weight) + copyValues[high]*weight, nil
}

type BottleneckInput struct {
	Layer              string
	MeanLatencySeconds float64
	Elasticity         float64
}

func Bottleneck(inputs []BottleneckInput) (string, map[string]float64, error) {
	var total float64
	for _, in := range inputs {
		if in.MeanLatencySeconds < 0 || in.Elasticity <= 0 {
			return "", nil, errors.New("invalid bottleneck input")
		}
		total += in.MeanLatencySeconds
	}
	if total == 0 {
		return "", nil, errors.New("total latency is zero")
	}
	scores := map[string]float64{}
	best := ""
	bestScore := -1.0
	for _, in := range inputs {
		score := (in.MeanLatencySeconds / total) / in.Elasticity
		scores[in.Layer] = score
		if score > bestScore {
			bestScore = score
			best = in.Layer
		}
	}
	return best, scores, nil
}
