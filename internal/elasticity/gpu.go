package elasticity

import (
	"errors"
	"math"
)

func GPUElasticity(drainSeconds, meanIntervalSeconds, mismatchProbability float64) (float64, error) {
	if drainSeconds < 0 || meanIntervalSeconds <= 0 || mismatchProbability < 0 || mismatchProbability > 1 {
		return 0, errors.New("invalid GPU parameters")
	}
	return math.Max(0, 1-mismatchProbability*drainSeconds/meanIntervalSeconds), nil
}
