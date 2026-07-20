package elasticity

import (
	"errors"
	"math"
)

func KEDAElasticityBound(lambda, coldStartSeconds, busyPeriodSeconds, cooldownSeconds float64) (float64, error) {
	if lambda <= 0 || coldStartSeconds < 0 || busyPeriodSeconds < 0 || cooldownSeconds < 0 {
		return 0, errors.New("invalid KEDA parameters")
	}
	exp := math.Exp(-lambda * cooldownSeconds)
	denominator := exp + lambda*coldStartSeconds + lambda*busyPeriodSeconds
	if denominator <= 0 {
		return 0, errors.New("invalid denominator")
	}
	pi0 := exp / denominator
	return 1 - pi0*coldStartSeconds/(coldStartSeconds+1/lambda), nil
}

func SolveKEDACooldown(lambda, coldStartSeconds, busyPeriodSeconds, target, maxSeconds float64) (float64, error) {
	if target <= 0 || target > 1 {
		return 0, errors.New("target must be in (0,1]")
	}
	if maxSeconds <= 0 {
		maxSeconds = 86400
	}
	atZero, err := KEDAElasticityBound(lambda, coldStartSeconds, busyPeriodSeconds, 0)
	if err != nil {
		return 0, err
	}
	if atZero >= target {
		return 0, nil
	}
	atMax, _ := KEDAElasticityBound(lambda, coldStartSeconds, busyPeriodSeconds, maxSeconds)
	if atMax < target {
		return 0, errors.New("target cannot be reached within maxSeconds")
	}
	low, high := 0.0, maxSeconds
	for i := 0; i < 80; i++ {
		mid := (low + high) / 2
		value, _ := KEDAElasticityBound(lambda, coldStartSeconds, busyPeriodSeconds, mid)
		if value >= target {
			high = mid
		} else {
			low = mid
		}
	}
	return high, nil
}
