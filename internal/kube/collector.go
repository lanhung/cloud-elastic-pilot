package kube

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"regexp"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

type Emitter interface{ Emit(event.Event) error }

type Config struct {
	ClusterID        string
	DefaultRunID     string
	HookeNamespace   string
	CaptureUnlabeled bool
	Kubeconfig       string
}

type Collector struct {
	cfg            Config
	client         kubernetes.Interface
	dynamic        dynamic.Interface
	discovery      discovery.DiscoveryInterface
	state          *State
	emitter        Emitter
	logger         *slog.Logger
	sourceInstance string
}

const (
	goatTaskIDKey          = "goatscaler.io/provision-task-id"
	goatProvisionNodeKey   = "goatscaler.io/provision-node-name"
	goatRescheduleDeadline = "goatscaler.io/reschedule-deadline"
)

func BuildConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig != "" {
		return clientcmd.BuildConfigFromFlags("", kubeconfig)
	}
	if config, err := rest.InClusterConfig(); err == nil {
		return config, nil
	}
	return clientcmd.BuildConfigFromFlags("", clientcmd.RecommendedHomeFile)
}

func NewCollector(cfg Config, emitter Emitter, logger *slog.Logger) (*Collector, error) {
	restConfig, err := BuildConfig(cfg.Kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("build kubernetes config: %w", err)
	}
	restConfig.UserAgent = "hooke-controller"
	client, err := kubernetes.NewForConfig(restConfig)
	if err != nil {
		return nil, err
	}
	dyn, err := dynamic.NewForConfig(restConfig)
	if err != nil {
		return nil, err
	}
	disco, err := discovery.NewDiscoveryClientForConfig(restConfig)
	if err != nil {
		return nil, err
	}
	host, _ := os.Hostname()
	return &Collector{cfg: cfg, client: client, dynamic: dyn, discovery: disco, state: NewState(cfg.DefaultRunID), emitter: emitter, logger: logger, sourceInstance: host}, nil
}

func (c *Collector) Run(ctx context.Context) error {
	factory := informers.NewSharedInformerFactory(c.client, 0)
	c.addNamespaceHandlers(factory.Core().V1().Namespaces().Informer())
	c.addConfigMapHandlers(factory.Core().V1().ConfigMaps().Informer())
	c.addPodHandlers(factory.Core().V1().Pods().Informer())
	c.addNodeHandlers(factory.Core().V1().Nodes().Informer())
	c.addKubernetesEventHandlers(factory.Core().V1().Events().Informer())
	c.addDeploymentHandlers(factory.Apps().V1().Deployments().Informer())
	c.addHPAHandlers(factory.Autoscaling().V2().HorizontalPodAutoscalers().Informer())
	factory.Start(ctx.Done())

	for _, started := range factory.WaitForCacheSync(ctx.Done()) {
		if !started {
			return fmt.Errorf("a core informer cache did not sync")
		}
	}
	c.startOptionalDynamicInformers(ctx)
	<-ctx.Done()
	return ctx.Err()
}

func (c *Collector) addNamespaceHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj any) { c.onNamespace(obj) },
		UpdateFunc: func(_, obj any) { c.onNamespace(obj) },
		DeleteFunc: func(obj any) {
			if ns, ok := object[*corev1.Namespace](obj); ok {
				c.state.SetNamespaceRun(ns.Name, "")
			}
		},
	})
}

func (c *Collector) onNamespace(obj any) {
	ns, ok := object[*corev1.Namespace](obj)
	if !ok {
		return
	}
	c.state.SetNamespaceRun(ns.Name, ns.Annotations["hooke.io/run-id"])
}

func (c *Collector) addConfigMapHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj any) { c.onConfigMap(obj) },
		UpdateFunc: func(_, obj any) { c.onConfigMap(obj) },
	})
}

func (c *Collector) onConfigMap(obj any) {
	cm, ok := object[*corev1.ConfigMap](obj)
	if !ok {
		return
	}
	if cm.Namespace == c.cfg.HookeNamespace && cm.Name == "hooke-active-run" {
		c.state.SetActiveRun(cm.Data["run_id"])
	}
}

func (c *Collector) addPodHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj any) { c.onPod(obj, false) },
		UpdateFunc: func(_, obj any) { c.onPod(obj, false) },
		DeleteFunc: func(obj any) { c.onPod(obj, true) },
	})
}

func (c *Collector) onPod(obj any, deleted bool) {
	pod, ok := object[*corev1.Pod](obj)
	if !ok {
		return
	}
	runID := c.state.RunID(pod.Namespace, pod.Annotations)
	if runID == "" && !c.cfg.CaptureUnlabeled {
		return
	}
	base := c.baseForPod(pod, runID)
	if taskID := stringAttribute(base.Attributes, "task_id"); taskID != "" {
		metadata := ProvisionMetadata{TaskID: taskID, NodeName: stringAttribute(base.Attributes, "provision_node_name")}
		c.state.SetPodProvision(string(pod.UID), metadata)
		attrs := map[string]any{
			"task_id":             metadata.TaskID,
			"provision_node_name": metadata.NodeName,
			"precision":           "goatscaler-pod-annotation",
		}
		c.emitIfChanged(base, event.ACKProvisionTaskUpdated, metadata.TaskID+"/"+metadata.NodeName, time.Now(), attrs, true)
	}
	if deleted {
		c.emitIfChanged(base, event.PodDeleted, pod.ResourceVersion+"/deleted", time.Now(), nil, false)
		return
	}
	c.emitIfChanged(base, event.PodCreated, string(pod.UID)+"/created", pod.CreationTimestamp.Time, nil, false)
	for _, condition := range pod.Status.Conditions {
		at := condition.LastTransitionTime.Time
		switch {
		case condition.Type == corev1.PodScheduled && condition.Status == corev1.ConditionTrue:
			attrs := map[string]any{"node_name": pod.Spec.NodeName}
			c.emitIfChanged(base, event.PodScheduled, string(condition.Status)+at.String(), at, attrs, false)
		case condition.Type == corev1.PodScheduled && condition.Status == corev1.ConditionFalse && condition.Reason == corev1.PodReasonUnschedulable:
			attrs := map[string]any{"message": condition.Message, "reason": condition.Reason}
			c.emitIfChanged(base, event.PodUnschedulable, condition.Reason+condition.Message+at.String(), at, attrs, false)
		case condition.Type == corev1.PodInitialized && condition.Status == corev1.ConditionTrue:
			c.emitIfChanged(base, event.PodInitialized, string(condition.Status)+at.String(), at, nil, false)
		case condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue:
			c.emitIfChanged(base, event.PodReady, string(condition.Status)+at.String(), at, nil, false)
			attrs := map[string]any{"precision": "pod-condition", "note": "readiness probe success approximated by Pod Ready transition"}
			c.emitIfChanged(base, event.ReadinessProbeFirstSuccess, string(condition.Status)+at.String(), at, attrs, true)
		}
	}
	statuses := append([]corev1.ContainerStatus{}, pod.Status.InitContainerStatuses...)
	statuses = append(statuses, pod.Status.ContainerStatuses...)
	for _, status := range statuses {
		if status.State.Running != nil {
			e := base
			e.ContainerName = status.Name
			e.ContainerID = status.ContainerID
			e.ImageRef = status.Image
			e.ImageDigest = status.ImageID
			c.emitIfChanged(e, event.ContainerStarted, status.ContainerID+status.State.Running.StartedAt.String(), status.State.Running.StartedAt.Time, nil, false)
		}
		if status.State.Terminated != nil {
			e := base
			e.ContainerName = status.Name
			e.ContainerID = status.ContainerID
			attrs := map[string]any{"exit_code": status.State.Terminated.ExitCode, "reason": status.State.Terminated.Reason}
			c.emitIfChanged(e, event.ContainerStopped, status.ContainerID+status.State.Terminated.FinishedAt.String(), status.State.Terminated.FinishedAt.Time, attrs, false)
		}
	}
}

func (c *Collector) addNodeHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj any) { c.onNode(obj) },
		UpdateFunc: func(_, obj any) { c.onNode(obj) },
	})
}

func (c *Collector) onNode(obj any) {
	node, ok := object[*corev1.Node](obj)
	if !ok {
		return
	}
	runID := c.state.RunID("", nil)
	if runID == "" {
		return
	}
	base := event.New(c.cfg.ClusterID, runID, event.NodeCreated, "kubernetes-node-watch", node.CreationTimestamp.Time)
	base.ClockType = event.ClockAPIServer
	base.SourceInstance = c.sourceInstance
	base.NodeName = node.Name
	base.NodeUID = string(node.UID)
	base.ResourceVersion = node.ResourceVersion
	base.Attributes = nodeProvisionAttributes(node)
	if taskID := stringAttribute(base.Attributes, "task_id"); taskID != "" {
		attrs := mergeAttributes(base.Attributes, map[string]any{"precision": "goatscaler-node-label"})
		c.emitIfChanged(base, event.ACKProvisionTaskUpdated, "node/"+taskID, time.Now(), attrs, true)
	}
	c.emitIfChanged(base, event.NodeCreated, string(node.UID)+"/created", node.CreationTimestamp.Time, base.Attributes, false)
	for _, condition := range node.Status.Conditions {
		if condition.Type != corev1.NodeReady {
			continue
		}
		if condition.Status == corev1.ConditionTrue {
			c.emitIfChanged(base, event.NodeReady, string(condition.Status)+condition.LastTransitionTime.String(), condition.LastTransitionTime.Time, map[string]any{"reason": condition.Reason}, false)
		} else {
			c.emitIfChanged(base, event.NodeNotReady, string(condition.Status)+condition.LastTransitionTime.String(), condition.LastTransitionTime.Time, map[string]any{"reason": condition.Reason}, false)
		}
	}
}

var quotedImage = regexp.MustCompile(`"([^"]+)"`)

func (c *Collector) addKubernetesEventHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc:    func(obj any) { c.onKubernetesEvent(obj) },
		UpdateFunc: func(_, obj any) { c.onKubernetesEvent(obj) },
	})
}

func (c *Collector) onKubernetesEvent(obj any) {
	ke, ok := object[*corev1.Event](obj)
	if !ok {
		return
	}
	if ke.InvolvedObject.Kind != "Pod" {
		return
	}
	runID := c.state.RunID(ke.Namespace, nil)
	if runID == "" && !c.cfg.CaptureUnlabeled {
		return
	}
	var eventType string
	switch ke.Reason {
	case "Pulling":
		eventType = event.ImagePullStart
	case "Pulled":
		eventType = event.ImagePullEnd
	case "Failed":
		if strings.Contains(strings.ToLower(ke.Message), "image") {
			eventType = event.ImagePullFail
		} else {
			return
		}
	case "FailedCreatePodSandBox", "FailedCreatePodSandbox":
		eventType = event.PodSandboxFail
	case "ProvisionNode":
		eventType = event.ACKProvisionRequested
	case "ProvisionNodeFailed":
		eventType = event.ACKProvisionFailed
	case "ResetPod":
		eventType = event.ACKProvisionTaskUpdated
	default:
		return
	}
	at := kubernetesEventTime(ke)
	e := event.New(c.cfg.ClusterID, runID, eventType, "kubernetes-event-watch", at)
	e.ClockType = event.ClockAPIServer
	e.SourceInstance = c.sourceInstance
	e.Namespace = ke.Namespace
	e.PodName = ke.InvolvedObject.Name
	e.PodUID = string(ke.InvolvedObject.UID)
	e.ResourceVersion = ke.ResourceVersion
	e.Reason = ke.Reason
	e.Approximate = true
	if (eventType == event.ImagePullStart || eventType == event.ImagePullEnd || eventType == event.ImagePullFail) && len(quotedImage.FindStringSubmatch(ke.Message)) == 2 {
		matches := quotedImage.FindStringSubmatch(ke.Message)
		e.ImageRef = matches[1]
	}
	e.Attributes = map[string]any{
		"message":               ke.Message,
		"count":                 ke.Count,
		"precision":             "kubernetes-event",
		"kubernetes_event_uid":  string(ke.UID),
		"involved_object_uid":   string(ke.InvolvedObject.UID),
		"reporting_controller":  ke.ReportingController,
		"reporting_instance":    ke.ReportingInstance,
		"source_component_name": ke.Source.Component,
		"source_component_host": ke.Source.Host,
	}
	if metadata, ok := c.state.PodProvision(string(ke.InvolvedObject.UID)); ok {
		e.Attributes["task_id"] = metadata.TaskID
		e.Attributes["provision_node_name"] = metadata.NodeName
	}
	fingerprint := fmt.Sprintf("%s/%d/%d", ke.UID, ke.Count, at.UnixNano())
	c.emitIfChanged(e, eventType, fingerprint, at, e.Attributes, true)
	if eventType == event.PodSandboxFail && isCNIFailure(ke.Message) {
		cni := e
		cni.Attributes = mergeAttributes(e.Attributes, map[string]any{"substage": "cni", "derived_from_event_type": event.PodSandboxFail})
		c.emitIfChanged(cni, event.CNISetupFail, fingerprint+"/cni", at, cni.Attributes, true)
	}
}

func isCNIFailure(message string) bool {
	normalized := strings.ToLower(message)
	for _, marker := range []string{"cni", "network plugin", "flannel", "subnet.env", "setup network"} {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func kubernetesEventTime(e *corev1.Event) time.Time {
	if !e.EventTime.IsZero() {
		return e.EventTime.Time
	}
	if !e.LastTimestamp.IsZero() {
		return e.LastTimestamp.Time
	}
	if !e.FirstTimestamp.IsZero() {
		return e.FirstTimestamp.Time
	}
	return e.CreationTimestamp.Time
}

func (c *Collector) addDeploymentHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{AddFunc: func(obj any) { c.onDeployment(obj) }, UpdateFunc: func(_, obj any) { c.onDeployment(obj) }})
}

func (c *Collector) onDeployment(obj any) {
	deployment, ok := object[*appsv1.Deployment](obj)
	if !ok {
		return
	}
	runID := c.state.RunID(deployment.Namespace, deployment.Annotations)
	if runID == "" && !c.cfg.CaptureUnlabeled {
		return
	}
	replicas := int32(1)
	if deployment.Spec.Replicas != nil {
		replicas = *deployment.Spec.Replicas
	}
	e := event.New(c.cfg.ClusterID, runID, event.DeploymentDesiredReplicasChanged, "kubernetes-deployment-watch", time.Now())
	e.ClockType = event.ClockAPIServer
	e.Namespace = deployment.Namespace
	e.WorkloadKind = "Deployment"
	e.WorkloadName = deployment.Name
	e.WorkloadUID = string(deployment.UID)
	e.ResourceVersion = deployment.ResourceVersion
	attrs := map[string]any{"desired_replicas": replicas, "observed_generation": deployment.Status.ObservedGeneration}
	c.emitIfChanged(e, event.DeploymentDesiredReplicasChanged, fmt.Sprint(deployment.Generation, "/", replicas), time.Now(), attrs, true)
}

func (c *Collector) addHPAHandlers(informer cache.SharedIndexInformer) {
	_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{AddFunc: func(obj any) { c.onHPA(obj) }, UpdateFunc: func(_, obj any) { c.onHPA(obj) }})
}

func (c *Collector) onHPA(obj any) {
	hpa, ok := object[*autoscalingv2.HorizontalPodAutoscaler](obj)
	if !ok {
		return
	}
	runID := c.state.RunID(hpa.Namespace, hpa.Annotations)
	if runID == "" && !c.cfg.CaptureUnlabeled {
		return
	}
	e := event.New(c.cfg.ClusterID, runID, event.HPADesiredReplicasChanged, "kubernetes-hpa-watch", time.Now())
	e.ClockType = event.ClockAPIServer
	e.Namespace = hpa.Namespace
	e.WorkloadKind = hpa.Spec.ScaleTargetRef.Kind
	e.WorkloadName = hpa.Spec.ScaleTargetRef.Name
	e.WorkloadUID = string(hpa.UID)
	e.ResourceVersion = hpa.ResourceVersion
	attrs := map[string]any{"current_replicas": hpa.Status.CurrentReplicas, "desired_replicas": hpa.Status.DesiredReplicas, "min_replicas": hpa.Spec.MinReplicas, "max_replicas": hpa.Spec.MaxReplicas}
	c.emitIfChanged(e, event.HPADesiredReplicasChanged, fmt.Sprint(hpa.Status.CurrentReplicas, "/", hpa.Status.DesiredReplicas, "/", hpa.ResourceVersion), time.Now(), attrs, true)
}

func (c *Collector) baseForPod(pod *corev1.Pod, runID string) event.Event {
	e := event.New(c.cfg.ClusterID, runID, "", "kubernetes-pod-watch", time.Now())
	e.ClockType = event.ClockAPIServer
	e.SourceInstance = c.sourceInstance
	e.Namespace = pod.Namespace
	e.PodName = pod.Name
	e.PodUID = string(pod.UID)
	e.NodeName = pod.Spec.NodeName
	e.ResourceVersion = pod.ResourceVersion
	e.Attributes = podProvisionAttributes(pod)
	if owner := metav1.GetControllerOf(pod); owner != nil {
		e.WorkloadKind = owner.Kind
		e.WorkloadName = owner.Name
		e.WorkloadUID = string(owner.UID)
	}
	return e
}

func (c *Collector) emitIfChanged(base event.Event, eventType, fingerprint string, at time.Time, attrs map[string]any, approximate bool) {
	key := strings.Join([]string{base.RunID, eventType, base.PodUID, base.NodeUID, base.ContainerName}, "/")
	if !c.state.Changed(key, fingerprint) {
		return
	}
	observedAt := time.Now().UTC()
	if at.IsZero() || at.UnixNano() <= 0 {
		at = observedAt
		approximate = true
		base.ClockType = event.ClockRealtime
		attrs = mergeAttributes(attrs, map[string]any{"event_time_fallback": "observed_time"})
	}
	base.EventType = eventType
	// A single informer callback can emit multiple atomic events from the same
	// base object. Give each emission its own identity so MySQL's event_id
	// uniqueness constraint does not collapse distinct event types.
	base.EventID = ""
	base.EventHash = ""
	base.SourceTimeNS = at.UTC().UnixNano()
	base.EventTimeNS = base.SourceTimeNS
	base.ObservedTimeNS = observedAt.UnixNano()
	base.Approximate = approximate
	base.Attributes = mergeAttributes(base.Attributes, attrs)
	base.Normalize()
	if err := c.emitter.Emit(base); err != nil {
		c.logger.Error("failed to enqueue event", "event_type", eventType, "error", err)
	}
}

func podProvisionAttributes(pod *corev1.Pod) map[string]any {
	attrs := map[string]any{}
	if value := pod.Annotations[goatTaskIDKey]; value != "" {
		attrs["task_id"] = value
	}
	if value := pod.Annotations[goatProvisionNodeKey]; value != "" {
		attrs["provision_node_name"] = value
	}
	if value := pod.Annotations[goatRescheduleDeadline]; value != "" {
		attrs["reschedule_deadline"] = value
	}
	return attrs
}

func nodeProvisionAttributes(node *corev1.Node) map[string]any {
	attrs := map[string]any{
		"provider_id": node.Spec.ProviderID,
	}
	if value := node.Labels[goatTaskIDKey]; value != "" {
		attrs["task_id"] = value
	}
	return attrs
}

func mergeAttributes(base, extra map[string]any) map[string]any {
	if len(base) == 0 && len(extra) == 0 {
		return map[string]any{}
	}
	merged := make(map[string]any, len(base)+len(extra))
	for key, value := range base {
		merged[key] = value
	}
	for key, value := range extra {
		merged[key] = value
	}
	return merged
}

func stringAttribute(attributes map[string]any, key string) string {
	value, _ := attributes[key].(string)
	return value
}

func object[T any](obj any) (T, bool) {
	value, ok := obj.(T)
	if ok {
		return value, true
	}
	if tombstone, ok := obj.(cache.DeletedFinalStateUnknown); ok {
		value, ok = tombstone.Obj.(T)
		return value, ok
	}
	var zero T
	return zero, false
}

var optionalResources = []schema.GroupVersionResource{
	{Group: "keda.sh", Version: "v1alpha1", Resource: "scaledobjects"},
	{Group: "kueue.x-k8s.io", Version: "v1beta1", Resource: "workloads"},
	{Group: "argoproj.io", Version: "v1alpha1", Resource: "workflows"},
	{Group: "resource.k8s.io", Version: "v1beta1", Resource: "resourceclaims"},
}

func (c *Collector) startOptionalDynamicInformers(ctx context.Context) {
	for _, gvr := range optionalResources {
		if _, err := c.discovery.ServerResourcesForGroupVersion(gvr.GroupVersion().String()); err != nil {
			c.logger.Info("optional API not installed", "gvr", gvr.String())
			continue
		}
		factory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(c.dynamic, 0, metav1.NamespaceAll, nil)
		informer := factory.ForResource(gvr).Informer()
		resource := gvr
		_, _ = informer.AddEventHandler(cache.ResourceEventHandlerFuncs{AddFunc: func(obj any) { c.onDynamic(resource, obj) }, UpdateFunc: func(_, obj any) { c.onDynamic(resource, obj) }})
		factory.Start(ctx.Done())
		c.logger.Info("started optional informer", "gvr", gvr.String())
	}
}

func (c *Collector) onDynamic(gvr schema.GroupVersionResource, obj any) {
	u, ok := obj.(*unstructured.Unstructured)
	if !ok {
		return
	}
	runID := c.state.RunID(u.GetNamespace(), u.GetAnnotations())
	if runID == "" && !c.cfg.CaptureUnlabeled {
		return
	}
	base := event.New(c.cfg.ClusterID, runID, "", "kubernetes-dynamic-watch", time.Now())
	base.ClockType = event.ClockAPIServer
	base.Namespace = u.GetNamespace()
	base.WorkloadKind = u.GetKind()
	base.WorkloadName = u.GetName()
	base.WorkloadUID = string(u.GetUID())
	base.ResourceVersion = u.GetResourceVersion()
	switch gvr.Resource {
	case "scaledobjects":
		c.emitKEDA(base, u)
	case "workloads":
		c.emitKueue(base, u)
	case "workflows":
		c.emitArgo(base, u)
	case "resourceclaims":
		attrs := map[string]any{"object": u.Object}
		c.emitIfChanged(base, "DRA_RESOURCECLAIM_UPDATED", u.GetResourceVersion(), time.Now(), attrs, true)
	}
}

func (c *Collector) emitKEDA(base event.Event, u *unstructured.Unstructured) {
	c.emitIfChanged(base, event.KEDAScaledObjectCreated, string(u.GetUID())+"/created", u.GetCreationTimestamp().Time, map[string]any{"spec": u.Object["spec"]}, false)
	conditions, _, _ := unstructured.NestedSlice(u.Object, "status", "conditions")
	for _, raw := range conditions {
		condition, _ := raw.(map[string]any)
		typ, _ := condition["type"].(string)
		status, _ := condition["status"].(string)
		transition, _ := condition["lastTransitionTime"].(string)
		var et string
		if typ == "Active" && status == "True" {
			et = event.KEDAScaledObjectActive
		}
		if typ == "Ready" && status == "True" {
			et = event.KEDAScaledObjectReady
		}
		if et == "" {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, transition)
		if at.IsZero() {
			at = time.Now()
		}
		c.emitIfChanged(base, et, typ+status+transition, at, map[string]any{"condition": condition}, false)
	}
}

func (c *Collector) emitKueue(base event.Event, u *unstructured.Unstructured) {
	c.emitIfChanged(base, event.KueueWorkloadCreated, string(u.GetUID())+"/created", u.GetCreationTimestamp().Time, map[string]any{"spec": u.Object["spec"]}, false)
	conditions, _, _ := unstructured.NestedSlice(u.Object, "status", "conditions")
	for _, raw := range conditions {
		condition, _ := raw.(map[string]any)
		typ, _ := condition["type"].(string)
		status, _ := condition["status"].(string)
		transition, _ := condition["lastTransitionTime"].(string)
		if status != "True" {
			continue
		}
		var et string
		switch typ {
		case "QuotaReserved":
			et = event.KueueQuotaReserved
		case "Admitted":
			et = event.KueueWorkloadAdmitted
		case "PodsReady":
			et = event.KueuePodsReady
		}
		if et == "" {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, transition)
		if at.IsZero() {
			at = time.Now()
		}
		c.emitIfChanged(base, et, typ+status+transition, at, map[string]any{"condition": condition}, false)
	}
}

func (c *Collector) emitArgo(base event.Event, u *unstructured.Unstructured) {
	c.emitIfChanged(base, event.ArgoWorkflowCreated, string(u.GetUID())+"/created", u.GetCreationTimestamp().Time, nil, false)
	phase, _, _ := unstructured.NestedString(u.Object, "status", "phase")
	started, _, _ := unstructured.NestedString(u.Object, "status", "startedAt")
	finished, _, _ := unstructured.NestedString(u.Object, "status", "finishedAt")
	if started != "" {
		at, _ := time.Parse(time.RFC3339Nano, started)
		c.emitIfChanged(base, event.ArgoWorkflowStarted, "started/"+started, at, map[string]any{"phase": phase}, false)
	}
	if finished != "" {
		at, _ := time.Parse(time.RFC3339Nano, finished)
		c.emitIfChanged(base, event.ArgoWorkflowFinished, "finished/"+finished, at, map[string]any{"phase": phase}, false)
	}
	nodes, _, _ := unstructured.NestedMap(u.Object, "status", "nodes")
	for id, raw := range nodes {
		node, _ := raw.(map[string]any)
		display, _ := node["displayName"].(string)
		nodePhase, _ := node["phase"].(string)
		st, _ := node["startedAt"].(string)
		ft, _ := node["finishedAt"].(string)
		stage := base
		stage.Attributes = map[string]any{"stage_id": id, "stage_name": display, "phase": nodePhase, "children": node["children"], "outbound_nodes": node["outboundNodes"]}
		if st != "" {
			at, _ := time.Parse(time.RFC3339Nano, st)
			c.emitIfChanged(stage, event.ArgoStageStarted, id+"/start/"+st, at, stage.Attributes, false)
		}
		if ft != "" {
			at, _ := time.Parse(time.RFC3339Nano, ft)
			c.emitIfChanged(stage, event.ArgoStageFinished, id+"/finish/"+ft, at, stage.Attributes, false)
		}
	}
}
