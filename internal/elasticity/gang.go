package elasticity

import (
	"errors"
	"math"
	"sort"
)

func KthOrder(values []float64, k int) (float64, error) {
	if k < 1 || k > len(values) {
		return 0, errors.New("k out of range")
	}
	copyValues := append([]float64(nil), values...)
	sort.Float64s(copyValues)
	return copyValues[k-1], nil
}

func GangElasticity(trials [][]float64, barrierSeconds []float64, k int, sloSeconds float64) (float64, float64, error) {
	if len(trials) == 0 || len(trials) != len(barrierSeconds) || sloSeconds <= 0 {
		return 0, 0, errors.New("invalid gang samples")
	}
	var total, barrierFactor float64
	for i, trial := range trials {
		order, err := KthOrder(trial, k)
		if err != nil {
			return 0, 0, err
		}
		if barrierSeconds[i] < 0 {
			return 0, 0, errors.New("barrier cannot be negative")
		}
		total += math.Exp(-(order + barrierSeconds[i]) / sloSeconds)
		barrierFactor += math.Exp(-barrierSeconds[i] / sloSeconds)
	}
	return total / float64(len(trials)), barrierFactor / float64(len(trials)), nil
}
