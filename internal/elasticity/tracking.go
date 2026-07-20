package elasticity

import (
	"errors"
	"math"
	"sort"
)

type CapacityPoint struct{ TimeSeconds, Supply, Demand float64 }

func TrackingScore(points []CapacityPoint) (raw, clipped float64, err error) {
	if len(points) < 2 {
		return 0, 0, errors.New("at least two capacity points are required")
	}
	sort.Slice(points, func(i, j int) bool { return points[i].TimeSeconds < points[j].TimeSeconds })
	var errorArea, demandArea float64
	for i := 1; i < len(points); i++ {
		dt := points[i].TimeSeconds - points[i-1].TimeSeconds
		if dt <= 0 {
			continue
		}
		e0 := math.Abs(points[i-1].Supply - points[i-1].Demand)
		e1 := math.Abs(points[i].Supply - points[i].Demand)
		errorArea += dt * (e0 + e1) / 2
		demandArea += dt * (points[i-1].Demand + points[i].Demand) / 2
	}
	if demandArea <= 0 {
		return 0, 0, errors.New("demand integral must be positive")
	}
	raw = 1 - errorArea/demandArea
	clipped = math.Max(0, math.Min(1, raw))
	return raw, clipped, nil
}
