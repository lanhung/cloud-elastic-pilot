package attribution

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

const (
	MethodTaskID         = "task-id"
	MethodKubernetesNode = "kubernetes-node"
	MethodTimeWindow     = "time-window"
)

type Link struct {
	PodUID           string `json:"pod_uid"`
	PodName          string `json:"pod_name,omitempty"`
	ExpectedTaskID   string `json:"expected_task_id"`
	ExpectedNodeName string `json:"expected_node_name,omitempty"`
	CandidateNode    string `json:"candidate_node,omitempty"`
	CandidateTaskID  string `json:"candidate_task_id,omitempty"`
	Correct          bool   `json:"correct"`
	Reason           string `json:"reason,omitempty"`
}

type MethodResult struct {
	Predictions   int     `json:"predictions"`
	TruePositive  int     `json:"true_positive"`
	FalsePositive int     `json:"false_positive"`
	FalseNegative int     `json:"false_negative"`
	Precision     float64 `json:"precision"`
	Recall        float64 `json:"recall"`
	F1            float64 `json:"f1"`
	Links         []Link  `json:"links"`
}

type Report struct {
	UnschedulablePods           int                     `json:"unschedulable_pods"`
	AttributedUnschedulablePods int                     `json:"attributed_unschedulable_pods"`
	GroundTruthPods             int                     `json:"ground_truth_pods"`
	UniqueTasks                 int                     `json:"unique_tasks"`
	ObservedNodes               int                     `json:"observed_nodes"`
	PodTaskIDCoverage           float64                 `json:"pod_task_id_coverage"`
	NodeTaskIDCoverage          float64                 `json:"node_task_id_coverage"`
	ProviderIDCoverage          float64                 `json:"provider_id_coverage"`
	InstanceIDCoverage          float64                 `json:"instance_id_coverage"`
	TaskNodeConflictCount       int                     `json:"task_node_conflict_count"`
	Conflicts                   []string                `json:"conflicts,omitempty"`
	Methods                     map[string]MethodResult `json:"methods"`
}

type podFact struct {
	uid               string
	name              string
	taskID            string
	ackTaskID         string
	provisionNodeName string
	scheduledNodeName string
	unschedulableNS   int64
}

type nodeFact struct {
	name       string
	taskID     string
	providerID string
	readyNS    int64
}

// Analyze treats GOATScaler's Pod task annotation and Node task label as the
// official relation. It evaluates two weaker fallbacks against that relation:
// the Pod's final scheduled Node and the first NodeReady inside a time window.
// The task ID is used only for evaluation of those fallback candidates.
func Analyze(events []event.Event, window time.Duration) Report {
	if window <= 0 {
		window = 10 * time.Minute
	}
	pods := map[string]*podFact{}
	nodes := map[string]*nodeFact{}
	instancesByTask := map[string]map[string]struct{}{}
	conflicts := map[string]struct{}{}

	for _, item := range events {
		taskID := attributeString(item.Attributes, "task_id")
		instanceID := attributeString(item.Attributes, "instance_id")

		if item.PodUID != "" {
			pod := ensurePod(pods, item.PodUID)
			if pod.name == "" {
				pod.name = item.PodName
			}
			if isPodAnnotationEvidence(item) {
				setConsistent(&pod.taskID, taskID, "pod "+item.PodUID+" annotation task", conflicts)
			}
			if item.EventType == event.ACKProvisionTaskCreated {
				setConsistent(&pod.ackTaskID, taskID, "pod "+item.PodUID+" ACK task", conflicts)
			}
			setConsistent(&pod.provisionNodeName, attributeString(item.Attributes, "provision_node_name"), "pod "+item.PodUID+" provision node", conflicts)
			if item.EventType == event.PodScheduled {
				nodeName := item.NodeName
				if nodeName == "" {
					nodeName = attributeString(item.Attributes, "node_name")
				}
				setConsistent(&pod.scheduledNodeName, nodeName, "pod "+item.PodUID+" scheduled node", conflicts)
			}
			if item.EventType == event.PodUnschedulable {
				setEarliest(&pod.unschedulableNS, item.EventTimeNS)
			}
		}

		isNodeEvidence := (item.SourceComponent == "kubernetes-node-watch" &&
			(item.EventType == event.NodeCreated || item.EventType == event.NodeReady)) ||
			(item.EventType == event.ACKProvisionTaskUpdated && item.PodUID == "" &&
				attributeString(item.Attributes, "precision") == "goatscaler-node-label")
		if item.NodeName != "" && isNodeEvidence {
			node := ensureNode(nodes, item.NodeName)
			setConsistent(&node.taskID, taskID, "node "+item.NodeName+" task", conflicts)
			setConsistent(&node.providerID, attributeString(item.Attributes, "provider_id"), "node "+item.NodeName+" provider", conflicts)
			if item.EventType == event.NodeReady {
				setEarliest(&node.readyNS, item.EventTimeNS)
			}
		}

		if taskID != "" && instanceID != "" {
			if instancesByTask[taskID] == nil {
				instancesByTask[taskID] = map[string]struct{}{}
			}
			instancesByTask[taskID][instanceID] = struct{}{}
		}

		if item.EventType == event.ACKProvisionTaskCreated && taskID != "" {
			for _, uid := range attributeStrings(item.Attributes, "pending_pod_uids") {
				pod := ensurePod(pods, uid)
				setConsistent(&pod.ackTaskID, taskID, "pod "+uid+" ACK task", conflicts)
			}
		}
	}
	for _, pod := range pods {
		if pod.taskID != "" && pod.ackTaskID != "" && pod.taskID != pod.ackTaskID {
			conflicts[fmt.Sprintf("pod %s annotation/ACK task: %q != %q", pod.uid, pod.taskID, pod.ackTaskID)] = struct{}{}
		}
	}

	nodesByTask := map[string][]string{}
	for name, node := range nodes {
		if node.taskID != "" {
			nodesByTask[node.taskID] = append(nodesByTask[node.taskID], name)
		}
	}
	for taskID := range nodesByTask {
		sort.Strings(nodesByTask[taskID])
	}

	groundTruth := groundTruthPods(pods)
	taskCandidates := taskIDCandidates(groundTruth, nodesByTask)
	kubernetesCandidates := map[string]string{}
	for uid, pod := range groundTruth {
		if pod.scheduledNodeName != "" {
			kubernetesCandidates[uid] = pod.scheduledNodeName
		}
	}
	timeCandidates := timeWindowCandidates(groundTruth, nodes, window)

	report := Report{
		UnschedulablePods:           countUnschedulable(pods),
		AttributedUnschedulablePods: countAttributedUnschedulable(pods),
		GroundTruthPods:             len(groundTruth),
		UniqueTasks:                 countTasks(groundTruth),
		ObservedNodes:               len(nodes),
		Methods: map[string]MethodResult{
			MethodTaskID:         evaluate(groundTruth, nodes, taskCandidates),
			MethodKubernetesNode: evaluate(groundTruth, nodes, kubernetesCandidates),
			MethodTimeWindow:     evaluate(groundTruth, nodes, timeCandidates),
		},
	}
	report.PodTaskIDCoverage = ratio(report.AttributedUnschedulablePods, report.UnschedulablePods)

	var nodesWithTask, nodesWithProvider int
	for _, node := range nodes {
		if node.taskID != "" {
			nodesWithTask++
		}
		if node.providerID != "" {
			nodesWithProvider++
		}
	}
	report.NodeTaskIDCoverage = ratio(nodesWithTask, report.ObservedNodes)
	report.ProviderIDCoverage = ratio(nodesWithProvider, report.ObservedNodes)
	var tasksWithInstance int
	for taskID := range uniqueTasks(groundTruth) {
		if len(instancesByTask[taskID]) > 0 {
			tasksWithInstance++
		}
	}
	report.InstanceIDCoverage = ratio(tasksWithInstance, report.UniqueTasks)

	for conflict := range conflicts {
		report.Conflicts = append(report.Conflicts, conflict)
	}
	sort.Strings(report.Conflicts)
	report.TaskNodeConflictCount = len(report.Conflicts)
	return report
}

func ensurePod(pods map[string]*podFact, uid string) *podFact {
	if pods[uid] == nil {
		pods[uid] = &podFact{uid: uid}
	}
	return pods[uid]
}

func ensureNode(nodes map[string]*nodeFact, name string) *nodeFact {
	if nodes[name] == nil {
		nodes[name] = &nodeFact{name: name}
	}
	return nodes[name]
}

func groundTruthPods(pods map[string]*podFact) map[string]*podFact {
	result := map[string]*podFact{}
	for uid, pod := range pods {
		if pod.taskID != "" {
			result[uid] = pod
		}
	}
	return result
}

func taskIDCandidates(pods map[string]*podFact, nodesByTask map[string][]string) map[string]string {
	result := map[string]string{}
	for uid, pod := range pods {
		candidates := nodesByTask[pod.taskID]
		if pod.provisionNodeName != "" {
			for _, candidate := range candidates {
				if candidate == pod.provisionNodeName {
					result[uid] = candidate
					break
				}
			}
			continue
		}
		if len(candidates) == 1 {
			result[uid] = candidates[0]
		}
	}
	return result
}

func timeWindowCandidates(pods map[string]*podFact, nodes map[string]*nodeFact, window time.Duration) map[string]string {
	type readyNode struct {
		name string
		at   int64
	}
	ready := make([]readyNode, 0, len(nodes))
	for name, node := range nodes {
		if node.readyNS > 0 {
			ready = append(ready, readyNode{name: name, at: node.readyNS})
		}
	}
	sort.Slice(ready, func(i, j int) bool {
		if ready[i].at == ready[j].at {
			return ready[i].name < ready[j].name
		}
		return ready[i].at < ready[j].at
	})

	result := map[string]string{}
	windowNS := int64(window)
	for uid, pod := range pods {
		if pod.unschedulableNS == 0 {
			continue
		}
		for _, node := range ready {
			if node.at >= pod.unschedulableNS && node.at-pod.unschedulableNS <= windowNS {
				result[uid] = node.name
				break
			}
		}
	}
	return result
}

func evaluate(pods map[string]*podFact, nodes map[string]*nodeFact, candidates map[string]string) MethodResult {
	result := MethodResult{}
	uids := make([]string, 0, len(pods))
	for uid := range pods {
		uids = append(uids, uid)
	}
	sort.Strings(uids)
	for _, uid := range uids {
		pod := pods[uid]
		candidate := candidates[uid]
		link := Link{
			PodUID:           uid,
			PodName:          pod.name,
			ExpectedTaskID:   pod.taskID,
			ExpectedNodeName: pod.provisionNodeName,
			CandidateNode:    candidate,
		}
		if candidate == "" {
			link.Reason = "no-candidate"
			result.Links = append(result.Links, link)
			continue
		}
		result.Predictions++
		if node := nodes[candidate]; node != nil {
			link.CandidateTaskID = node.taskID
		}
		switch {
		case link.CandidateTaskID != "":
			link.Correct = link.CandidateTaskID == pod.taskID
			if !link.Correct {
				link.Reason = "task-id-mismatch"
			}
		case pod.provisionNodeName != "":
			link.Correct = candidate == pod.provisionNodeName
			if !link.Correct {
				link.Reason = "provision-node-mismatch"
			}
		default:
			link.Reason = "candidate-has-no-task-id"
		}
		if link.Correct {
			result.TruePositive++
		} else {
			result.FalsePositive++
		}
		result.Links = append(result.Links, link)
	}
	result.FalseNegative = len(pods) - result.TruePositive
	result.Precision = ratio(result.TruePositive, result.Predictions)
	result.Recall = ratio(result.TruePositive, len(pods))
	if result.Precision+result.Recall > 0 {
		result.F1 = 2 * result.Precision * result.Recall / (result.Precision + result.Recall)
	}
	return result
}

func countUnschedulable(pods map[string]*podFact) int {
	count := 0
	for _, pod := range pods {
		if pod.unschedulableNS > 0 {
			count++
		}
	}
	return count
}

func countAttributedUnschedulable(pods map[string]*podFact) int {
	count := 0
	for _, pod := range pods {
		if pod.unschedulableNS > 0 && pod.taskID != "" {
			count++
		}
	}
	return count
}

func countTasks(pods map[string]*podFact) int { return len(uniqueTasks(pods)) }

func uniqueTasks(pods map[string]*podFact) map[string]struct{} {
	result := map[string]struct{}{}
	for _, pod := range pods {
		if pod.taskID != "" {
			result[pod.taskID] = struct{}{}
		}
	}
	return result
}

func ratio(numerator, denominator int) float64 {
	if denominator == 0 {
		return 0
	}
	return float64(numerator) / float64(denominator)
}

func setConsistent(destination *string, value, label string, conflicts map[string]struct{}) {
	value = strings.TrimSpace(value)
	if value == "" {
		return
	}
	if *destination == "" {
		*destination = value
		return
	}
	if *destination != value {
		conflicts[fmt.Sprintf("%s: %q != %q", label, *destination, value)] = struct{}{}
	}
}

func setEarliest(destination *int64, value int64) {
	if value > 0 && (*destination == 0 || value < *destination) {
		*destination = value
	}
}

func attributeString(attributes map[string]any, key string) string {
	value, _ := attributes[key].(string)
	return strings.TrimSpace(value)
}

func isPodAnnotationEvidence(item event.Event) bool {
	if attributeString(item.Attributes, "task_id") == "" {
		return false
	}
	return item.SourceComponent == "kubernetes-pod-watch" ||
		attributeString(item.Attributes, "precision") == "goatscaler-pod-annotation"
}

func attributeStrings(attributes map[string]any, key string) []string {
	value := attributes[key]
	var result []string
	switch typed := value.(type) {
	case []string:
		result = append(result, typed...)
	case []any:
		for _, raw := range typed {
			if item, ok := raw.(string); ok && strings.TrimSpace(item) != "" {
				result = append(result, strings.TrimSpace(item))
			}
		}
	case string:
		if strings.TrimSpace(typed) != "" {
			result = append(result, strings.TrimSpace(typed))
		}
	}
	return result
}
