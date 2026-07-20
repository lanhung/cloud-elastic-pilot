package elasticity

import (
	"errors"
	"fmt"
	"sort"
)

type Stage struct {
	ID              string
	DurationSeconds float64
	Elasticity      float64
}
type Edge struct{ From, To string }
type CriticalPathResult struct {
	StageIDs          []string
	DurationSeconds   float64
	ElasticityProduct float64
}

func WorkflowCriticalPath(stages []Stage, edges []Edge) (CriticalPathResult, error) {
	byID := map[string]Stage{}
	indegree := map[string]int{}
	next := map[string][]string{}
	for _, stage := range stages {
		if stage.ID == "" || stage.DurationSeconds < 0 || stage.Elasticity < 0 || stage.Elasticity > 1 {
			return CriticalPathResult{}, errors.New("invalid stage")
		}
		if _, exists := byID[stage.ID]; exists {
			return CriticalPathResult{}, fmt.Errorf("duplicate stage %s", stage.ID)
		}
		byID[stage.ID] = stage
		indegree[stage.ID] = 0
	}
	for _, edge := range edges {
		if _, ok := byID[edge.From]; !ok {
			return CriticalPathResult{}, fmt.Errorf("unknown source %s", edge.From)
		}
		if _, ok := byID[edge.To]; !ok {
			return CriticalPathResult{}, fmt.Errorf("unknown target %s", edge.To)
		}
		next[edge.From] = append(next[edge.From], edge.To)
		indegree[edge.To]++
	}
	queue := []string{}
	for id, degree := range indegree {
		if degree == 0 {
			queue = append(queue, id)
		}
	}
	sort.Strings(queue)
	distance := map[string]float64{}
	product := map[string]float64{}
	previous := map[string]string{}
	for id := range byID {
		distance[id] = byID[id].DurationSeconds
		product[id] = byID[id].Elasticity
	}
	visited := 0
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		visited++
		for _, target := range next[id] {
			candidate := distance[id] + byID[target].DurationSeconds
			if candidate > distance[target] {
				distance[target] = candidate
				product[target] = product[id] * byID[target].Elasticity
				previous[target] = id
			}
			indegree[target]--
			if indegree[target] == 0 {
				queue = append(queue, target)
				sort.Strings(queue)
			}
		}
	}
	if visited != len(stages) {
		return CriticalPathResult{}, errors.New("workflow graph contains a cycle")
	}
	end := ""
	for id, value := range distance {
		if end == "" || value > distance[end] {
			end = id
		}
	}
	path := []string{}
	for current := end; current != ""; current = previous[current] {
		path = append(path, current)
	}
	for i, j := 0, len(path)-1; i < j; i, j = i+1, j-1 {
		path[i], path[j] = path[j], path[i]
	}
	return CriticalPathResult{StageIDs: path, DurationSeconds: distance[end], ElasticityProduct: product[end]}, nil
}
