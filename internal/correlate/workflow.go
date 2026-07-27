package correlate

import (
	"errors"
	"fmt"
	"math"
	"sort"

	"github.com/hooke-repro/hooke-ack/internal/elasticity"
	"github.com/hooke-repro/hooke-ack/internal/event"
)

type WorkflowAnalysis struct {
	WorkflowCount int                      `json:"workflow_count"`
	CompleteCount int                      `json:"complete_count"`
	Results       []WorkflowCriticalResult `json:"results"`
	Edges         []WorkflowEdgeEvidence   `json:"-"`
}

type WorkflowCriticalResult struct {
	WorkflowUID              string   `json:"workflow_uid"`
	WorkflowName             string   `json:"workflow_name"`
	Variant                  string   `json:"variant,omitempty"`
	Phase                    string   `json:"phase,omitempty"`
	Complete                 bool     `json:"complete"`
	StageCount               int      `json:"stage_count"`
	EdgeCount                int      `json:"edge_count"`
	CriticalPathStageIDs     []string `json:"critical_path_stage_ids,omitempty"`
	CriticalPathStageNames   []string `json:"critical_path_stage_names,omitempty"`
	CriticalPathLength       int      `json:"critical_path_length"`
	CriticalPathSeconds      float64  `json:"critical_path_seconds"`
	WorkflowDurationSeconds  float64  `json:"workflow_duration_seconds"`
	PredictedElasticity      float64  `json:"predicted_elasticity"`
	MeasuredElasticity       float64  `json:"measured_elasticity"`
	ModelAbsoluteError       float64  `json:"model_absolute_error"`
	ElasticitySLOSeconds     float64  `json:"elasticity_slo_seconds"`
	IncompleteOrInvalidCause string   `json:"incomplete_or_invalid_cause,omitempty"`
}

type WorkflowEdgeEvidence struct {
	WorkflowUID    string `json:"workflow_uid"`
	FromStageID    string `json:"from_stage_id"`
	ToStageID      string `json:"to_stage_id"`
	DependencyType string `json:"dependency_type"`
}

type workflowFacts struct {
	uid      string
	name     string
	variant  string
	phase    string
	startNS  int64
	finishNS int64
	stages   map[string]*workflowStageFacts
	edges    map[elasticity.Edge]string
}

type workflowStageFacts struct {
	id       string
	name     string
	nodeType string
	phase    string
	startNS  int64
	finishNS int64
}

func AnalyzeWorkflows(events []event.Event, sloSeconds float64) (WorkflowAnalysis, error) {
	if sloSeconds <= 0 || math.IsNaN(sloSeconds) || math.IsInf(sloSeconds, 0) {
		return WorkflowAnalysis{}, errors.New("workflow SLO must be positive and finite")
	}
	byUID := map[string]*workflowFacts{}
	for _, item := range events {
		if item.WorkloadUID == "" {
			continue
		}
		switch item.EventType {
		case event.ArgoWorkflowCreated,
			event.ArgoWorkflowStarted,
			event.ArgoWorkflowFinished,
			event.ArgoStageStarted,
			event.ArgoStageFinished,
			event.ArgoWorkflowEdge:
		default:
			continue
		}
		facts := byUID[item.WorkloadUID]
		if facts == nil {
			facts = &workflowFacts{
				uid:    item.WorkloadUID,
				name:   item.WorkloadName,
				stages: map[string]*workflowStageFacts{},
				edges:  map[elasticity.Edge]string{},
			}
			byUID[item.WorkloadUID] = facts
		}
		if facts.name == "" {
			facts.name = item.WorkloadName
		}
		switch item.EventType {
		case event.ArgoWorkflowCreated:
			if variant := workflowAttributeString(item.Attributes, "protocol_variant"); variant != "" {
				facts.variant = variant
			}
		case event.ArgoWorkflowStarted:
			facts.startNS = earliestPositive(facts.startNS, item.EventTimeNS)
			if phase := workflowAttributeString(item.Attributes, "phase"); phase != "" {
				facts.phase = phase
			}
		case event.ArgoWorkflowFinished:
			facts.finishNS = latestPositive(facts.finishNS, item.EventTimeNS)
			if phase := workflowAttributeString(item.Attributes, "phase"); phase != "" {
				facts.phase = phase
			}
		case event.ArgoStageStarted, event.ArgoStageFinished:
			stageID := workflowAttributeString(item.Attributes, "stage_id")
			if stageID == "" {
				continue
			}
			stage := facts.stages[stageID]
			if stage == nil {
				stage = &workflowStageFacts{id: stageID}
				facts.stages[stageID] = stage
			}
			if name := workflowAttributeString(item.Attributes, "stage_name"); name != "" {
				stage.name = name
			}
			if nodeType := workflowAttributeString(item.Attributes, "node_type"); nodeType != "" {
				stage.nodeType = nodeType
			}
			if phase := workflowAttributeString(item.Attributes, "phase"); phase != "" {
				stage.phase = phase
			}
			if item.EventType == event.ArgoStageStarted {
				stage.startNS = earliestPositive(stage.startNS, item.EventTimeNS)
			} else {
				stage.finishNS = latestPositive(stage.finishNS, item.EventTimeNS)
			}
		case event.ArgoWorkflowEdge:
			from := workflowAttributeString(item.Attributes, "from_stage_id")
			to := workflowAttributeString(item.Attributes, "to_stage_id")
			if from == "" || to == "" {
				continue
			}
			dependencyType := workflowAttributeString(item.Attributes, "dependency_type")
			if dependencyType == "" {
				dependencyType = "control"
			}
			facts.edges[elasticity.Edge{From: from, To: to}] = dependencyType
		}
	}

	uids := make([]string, 0, len(byUID))
	for uid := range byUID {
		uids = append(uids, uid)
	}
	sort.Strings(uids)
	analysis := WorkflowAnalysis{WorkflowCount: len(uids)}
	for _, uid := range uids {
		result, edges := analyzeWorkflow(byUID[uid], sloSeconds)
		if result.Complete {
			analysis.CompleteCount++
		}
		analysis.Results = append(analysis.Results, result)
		analysis.Edges = append(analysis.Edges, edges...)
	}
	return analysis, nil
}

func analyzeWorkflow(facts *workflowFacts, sloSeconds float64) (WorkflowCriticalResult, []WorkflowEdgeEvidence) {
	result := WorkflowCriticalResult{
		WorkflowUID:          facts.uid,
		WorkflowName:         facts.name,
		Variant:              facts.variant,
		Phase:                facts.phase,
		ElasticitySLOSeconds: sloSeconds,
	}
	stageIDs := make([]string, 0, len(facts.stages))
	for id, stage := range facts.stages {
		if stage.nodeType == "" || stage.nodeType == "Pod" {
			stageIDs = append(stageIDs, id)
		}
	}
	sort.Strings(stageIDs)
	stageSet := make(map[string]struct{}, len(stageIDs))
	stages := make([]elasticity.Stage, 0, len(stageIDs))
	names := make(map[string]string, len(stageIDs))
	for _, id := range stageIDs {
		stageSet[id] = struct{}{}
		stage := facts.stages[id]
		names[id] = stage.name
		if stage.startNS <= 0 || stage.finishNS < stage.startNS {
			result.IncompleteOrInvalidCause = fmt.Sprintf("stage %s has incomplete timestamps", id)
			result.StageCount = len(stageIDs)
			return result, nil
		}
		if stage.phase != "" && stage.phase != "Succeeded" {
			result.IncompleteOrInvalidCause = fmt.Sprintf("stage %s phase is %s", id, stage.phase)
			result.StageCount = len(stageIDs)
			return result, nil
		}
		duration := float64(stage.finishNS-stage.startNS) / 1e9
		stages = append(stages, elasticity.Stage{
			ID:              id,
			DurationSeconds: duration,
			Elasticity:      math.Exp(-duration / sloSeconds),
		})
	}
	result.StageCount = len(stages)
	logicalEdges := collapseWorkflowEdges(stageSet, facts.edges)
	edges := make([]elasticity.Edge, 0, len(logicalEdges))
	evidence := make([]WorkflowEdgeEvidence, 0, len(logicalEdges))
	for edge, dependencyType := range logicalEdges {
		edges = append(edges, edge)
		evidence = append(evidence, WorkflowEdgeEvidence{
			WorkflowUID: facts.uid, FromStageID: edge.From, ToStageID: edge.To, DependencyType: dependencyType,
		})
	}
	sort.Slice(edges, func(i, j int) bool {
		if edges[i].From == edges[j].From {
			return edges[i].To < edges[j].To
		}
		return edges[i].From < edges[j].From
	})
	sort.Slice(evidence, func(i, j int) bool {
		if evidence[i].FromStageID == evidence[j].FromStageID {
			return evidence[i].ToStageID < evidence[j].ToStageID
		}
		return evidence[i].FromStageID < evidence[j].FromStageID
	})
	result.EdgeCount = len(edges)
	if facts.startNS <= 0 || facts.finishNS < facts.startNS {
		result.IncompleteOrInvalidCause = "workflow has incomplete timestamps"
		return result, evidence
	}
	if facts.phase != "" && facts.phase != "Succeeded" {
		result.IncompleteOrInvalidCause = fmt.Sprintf("workflow phase is %s", facts.phase)
		return result, evidence
	}
	critical, err := elasticity.WorkflowCriticalPath(stages, edges)
	if err != nil {
		result.IncompleteOrInvalidCause = err.Error()
		return result, evidence
	}
	result.CriticalPathStageIDs = critical.StageIDs
	for _, id := range critical.StageIDs {
		name := names[id]
		if name == "" {
			name = id
		}
		result.CriticalPathStageNames = append(result.CriticalPathStageNames, name)
	}
	result.CriticalPathLength = len(critical.StageIDs)
	result.CriticalPathSeconds = critical.DurationSeconds
	result.WorkflowDurationSeconds = float64(facts.finishNS-facts.startNS) / 1e9
	result.PredictedElasticity = critical.ElasticityProduct
	result.MeasuredElasticity = math.Exp(-result.WorkflowDurationSeconds / sloSeconds)
	result.ModelAbsoluteError = math.Abs(result.MeasuredElasticity - result.PredictedElasticity)
	result.Complete = true
	return result, evidence
}

func collapseWorkflowEdges(stageSet map[string]struct{}, raw map[elasticity.Edge]string) map[elasticity.Edge]string {
	outgoing := map[string][]string{}
	for edge := range raw {
		outgoing[edge.From] = append(outgoing[edge.From], edge.To)
	}
	for id := range outgoing {
		sort.Strings(outgoing[id])
	}
	result := map[elasticity.Edge]string{}
	for source := range stageSet {
		queue := append([]string(nil), outgoing[source]...)
		seen := map[string]struct{}{source: {}}
		for len(queue) > 0 {
			target := queue[0]
			queue = queue[1:]
			if _, visited := seen[target]; visited {
				continue
			}
			seen[target] = struct{}{}
			if _, logical := stageSet[target]; logical {
				if target != source {
					result[elasticity.Edge{From: source, To: target}] = "control"
				}
				continue
			}
			queue = append(queue, outgoing[target]...)
		}
	}
	return result
}

func workflowAttributeString(attributes map[string]any, key string) string {
	if attributes == nil {
		return ""
	}
	value, _ := attributes[key].(string)
	return value
}

func earliestPositive(current, candidate int64) int64 {
	if candidate <= 0 {
		return current
	}
	if current <= 0 || candidate < current {
		return candidate
	}
	return current
}

func latestPositive(current, candidate int64) int64 {
	if candidate > current {
		return candidate
	}
	return current
}
