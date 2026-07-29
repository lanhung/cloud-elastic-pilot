package kube

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

const (
	migCapableLabel      = "nvidia.com/mig.capable"
	migConfigLabel       = "nvidia.com/mig.config"
	migConfigStateLabel  = "nvidia.com/mig.config.state"
	migStrategyLabel     = "nvidia.com/mig.strategy"
	gpuProductLabel      = "nvidia.com/gpu.product"
	gpuCountLabel        = "nvidia.com/gpu.count"
	migRequestedAtKey    = "hooke.io/mig-requested-at"
	migRequestIDKey      = "hooke.io/mig-request-id"
	migRequestProfileKey = "hooke.io/mig-request-profile"
	migRunIDKey          = "hooke.io/mig-run-id"
)

type draDeviceAllocation struct {
	Request string `json:"request,omitempty"`
	Driver  string `json:"driver,omitempty"`
	Pool    string `json:"pool,omitempty"`
	Device  string `json:"device,omitempty"`
	ShareID string `json:"share_id,omitempty"`
}

type draConsumer struct {
	APIGroup string `json:"api_group,omitempty"`
	Resource string `json:"resource,omitempty"`
	Name     string `json:"name,omitempty"`
	UID      string `json:"uid,omitempty"`
}

type draPublishedDevice struct {
	Name       string `json:"name"`
	UUID       string `json:"uuid,omitempty"`
	Type       string `json:"type,omitempty"`
	Profile    string `json:"profile,omitempty"`
	ParentUUID string `json:"parent_uuid,omitempty"`
}

func (c *Collector) emitDRAResourceClaim(base event.Event, claim *unstructured.Unstructured) {
	deviceClasses := resourceClaimDeviceClasses(claim)
	allocations := resourceClaimAllocations(claim)
	consumers := resourceClaimConsumers(claim)
	deviceIDs := make([]string, 0, len(allocations))
	drivers := make([]string, 0, len(allocations))
	for _, allocation := range allocations {
		deviceIDs = append(deviceIDs, allocationDeviceID(allocation))
		drivers = append(drivers, allocation.Driver)
	}
	deviceIDs = uniqueSorted(deviceIDs)
	drivers = uniqueSorted(drivers)
	c.state.SetResourceClaim(claim.GetNamespace(), claim.GetName(), ResourceClaimMetadata{
		UID:           string(claim.GetUID()),
		DeviceClasses: deviceClasses,
		DeviceIDs:     deviceIDs,
		Drivers:       drivers,
	})

	base.WorkloadKind = "ResourceClaim"
	base.WorkloadName = claim.GetName()
	base.WorkloadUID = string(claim.GetUID())
	claimBase := base
	if pod, ok := singlePodConsumer(consumers); ok {
		base.PodName = pod.Name
		base.PodUID = pod.UID
	}
	attrs := map[string]any{
		"claim_name":        claim.GetName(),
		"claim_uid":         string(claim.GetUID()),
		"api_version":       claim.GetAPIVersion(),
		"device_classes":    deviceClasses,
		"allocated_devices": allocations,
		"consumers":         consumers,
	}
	c.emitIfChanged(
		claimBase,
		event.DRAResourceClaimCreated,
		string(claim.GetUID())+"/created",
		claim.GetCreationTimestamp().Time,
		mergeAttributes(attrs, map[string]any{
			"precision": "resourceclaim-metadata.creationTimestamp",
		}),
		false,
	)

	if len(allocations) > 0 {
		allocationAt, exact := nestedTimestamp(claim.Object, "status", "allocation", "allocationTimestamp")
		allocationBase := claimBase
		precision := "resourceclaim-status-allocation-observation"
		if !exact {
			allocationAt = time.Now().UTC()
			allocationBase.ClockType = event.ClockRealtime
		} else {
			precision = "resourceclaim-status-allocationTimestamp"
		}
		c.emitIfChanged(
			allocationBase,
			event.DRAResourceClaimAllocated,
			stableFingerprint(allocations),
			allocationAt,
			mergeAttributes(attrs, map[string]any{
				"allocation_timestamp_present": exact,
				"precision":                    precision,
			}),
			!exact,
		)
	}

	if len(consumers) > 0 {
		reservedBase := base
		reservedBase.ClockType = event.ClockRealtime
		c.emitIfChanged(
			reservedBase,
			event.DRAResourceClaimReserved,
			stableFingerprint(consumers),
			time.Now().UTC(),
			mergeAttributes(attrs, map[string]any{
				"precision": "resourceclaim-status-reservedFor-observation",
			}),
			true,
		)
	}

	preparedAt, prepared, exact := resourceClaimPreparedAt(claim, allocations)
	if !prepared {
		return
	}
	preparedBase := claimBase
	precision := "resourceclaim-status-device-ready-condition"
	if !exact {
		preparedAt = time.Now().UTC()
		preparedBase.ClockType = event.ClockRealtime
		precision = "resourceclaim-status-device-ready-observation"
	}
	c.emitIfChanged(
		preparedBase,
		event.DRAResourceClaimPrepared,
		stableFingerprint(resourceClaimDeviceStatuses(claim)),
		preparedAt,
		mergeAttributes(attrs, map[string]any{
			"precision": precision,
			"note":      "emitted only when every allocated device has an explicit Ready=True condition",
		}),
		!exact,
	)
}

func (c *Collector) emitDRAResourceSlice(base event.Event, resourceSlice *unstructured.Unstructured) {
	driver, _, _ := unstructured.NestedString(resourceSlice.Object, "spec", "driver")
	nodeName, _, _ := unstructured.NestedString(resourceSlice.Object, "spec", "nodeName")
	allNodes, _, _ := unstructured.NestedBool(resourceSlice.Object, "spec", "allNodes")
	pool, _, _ := unstructured.NestedMap(resourceSlice.Object, "spec", "pool")
	devices, _, _ := unstructured.NestedSlice(resourceSlice.Object, "spec", "devices")
	publishedDevices := resourceSlicePublishedDevices(devices)
	deviceNames := make([]string, 0, len(publishedDevices))
	for _, device := range publishedDevices {
		deviceNames = append(deviceNames, device.Name)
	}
	attrs := map[string]any{
		"resource_slice_name":  resourceSlice.GetName(),
		"resource_slice_uid":   string(resourceSlice.GetUID()),
		"api_version":          resourceSlice.GetAPIVersion(),
		"driver":               driver,
		"node_name":            nodeName,
		"all_nodes":            allNodes,
		"pool_name":            stringMapValue(pool, "name"),
		"pool_generation":      pool["generation"],
		"resource_slice_count": pool["resourceSliceCount"],
		"device_count":         len(deviceNames),
		"device_names":         deviceNames,
		"published_devices":    publishedDevices,
	}
	base.NodeName = nodeName
	stateKey := strings.Join([]string{"dra-resourceslice", base.RunID, string(resourceSlice.GetUID())}, "/")
	fingerprint := stableFingerprint(map[string]any{
		"driver": driver, "node_name": nodeName, "pool": pool, "devices": publishedDevices,
	})
	previous, existed := c.state.ReplaceFingerprint(stateKey, fingerprint)
	if existed && previous == fingerprint {
		return
	}
	at := resourceSlice.GetCreationTimestamp().Time
	approximate := false
	attrs["observation"] = "created"
	if existed {
		at = time.Now().UTC()
		approximate = true
		base.ClockType = event.ClockRealtime
		attrs["observation"] = "updated"
	}
	attrs["precision"] = map[bool]string{
		false: "resourceslice-metadata.creationTimestamp",
		true:  "resourceslice-spec-observation",
	}[approximate]
	c.emitIfChangedWithKey(
		base,
		event.DRAResourceSlicePublished,
		string(resourceSlice.GetUID()),
		fingerprint,
		at,
		attrs,
		approximate,
	)
}

func resourceSlicePublishedDevices(devices []any) []draPublishedDevice {
	published := make([]draPublishedDevice, 0, len(devices))
	for _, raw := range devices {
		device, _ := raw.(map[string]any)
		name := stringMapValue(device, "name")
		if name == "" {
			continue
		}
		published = append(published, draPublishedDevice{
			Name:       name,
			UUID:       deviceAttributeString(device, "uuid"),
			Type:       deviceAttributeString(device, "type"),
			Profile:    deviceAttributeString(device, "profile"),
			ParentUUID: deviceAttributeString(device, "parentUUID"),
		})
	}
	sort.Slice(published, func(i, j int) bool { return published[i].Name < published[j].Name })
	return published
}

func deviceAttributeString(device map[string]any, name string) string {
	attributes, _ := device["attributes"].(map[string]any)
	if basic, ok := device["basic"].(map[string]any); ok {
		if legacy, ok := basic["attributes"].(map[string]any); ok {
			attributes = legacy
		}
	}
	for _, key := range []string{name, "gpu.nvidia.com/" + name} {
		if value, ok := attributes[key].(map[string]any); ok {
			if result := stringMapValue(value, "string"); result != "" {
				return result
			}
		}
	}
	if domain, ok := attributes["gpu.nvidia.com"].(map[string]any); ok {
		if value, ok := domain[name].(map[string]any); ok {
			return stringMapValue(value, "string")
		}
	}
	return ""
}

func (c *Collector) emitDRADeviceClass(base event.Event, deviceClass *unstructured.Unstructured) {
	selectors, _, _ := unstructured.NestedSlice(deviceClass.Object, "spec", "selectors")
	config, _, _ := unstructured.NestedSlice(deviceClass.Object, "spec", "config")
	extendedResourceName, _, _ := unstructured.NestedString(deviceClass.Object, "spec", "extendedResourceName")
	drivers := opaqueConfigDrivers(config)
	attrs := map[string]any{
		"device_class_name":      deviceClass.GetName(),
		"device_class_uid":       string(deviceClass.GetUID()),
		"api_version":            deviceClass.GetAPIVersion(),
		"selector_count":         len(selectors),
		"config_count":           len(config),
		"config_drivers":         drivers,
		"extended_resource_name": extendedResourceName,
		"precision":              "deviceclass-metadata.creationTimestamp",
	}
	c.emitIfChanged(
		base,
		event.DRADeviceClassAvailable,
		string(deviceClass.GetUID())+"/created",
		deviceClass.GetCreationTimestamp().Time,
		attrs,
		false,
	)
}

func (c *Collector) emitMIGNodeLifecycle(base event.Event, node *corev1.Node) {
	labels := node.GetLabels()
	if labels[migCapableLabel] != "true" && labels[migConfigLabel] == "" {
		return
	}
	annotations := node.GetAnnotations()
	requestID := annotations[migRequestIDKey]
	requestProfile := annotations[migRequestProfileKey]
	profile := labels[migConfigLabel]
	state := labels[migConfigStateLabel]
	common := map[string]any{
		"mig_profile":      profile,
		"mig_config_state": state,
		"mig_strategy":     labels[migStrategyLabel],
		"gpu_product":      labels[gpuProductLabel],
		"gpu_count":        labels[gpuCountLabel],
		"mig_request_id":   requestID,
		"mig_run_id":       annotations[migRunIDKey],
	}

	configStateKey := strings.Join([]string{"mig-config", base.RunID, string(node.UID)}, "/")
	previousProfile, profileExisted := c.state.ReplaceFingerprint(configStateKey, profile)
	if profileExisted && previousProfile != profile {
		at, exact := annotationTimestamp(annotations[migRequestedAtKey])
		requestBase := base
		precision := "node-label-observation"
		if !exact || requestProfile != profile {
			at = time.Now().UTC()
			requestBase.ClockType = event.ClockRealtime
			exact = false
		} else {
			precision = "runner-request-annotation"
		}
		attrs := mergeAttributes(common, map[string]any{
			"previous_mig_profile":  previousProfile,
			"requested_mig_profile": profile,
			"precision":             precision,
		})
		c.emitIfChanged(
			requestBase,
			event.MIGReshapeRequested,
			previousProfile+"->"+profile+"/"+requestID,
			at,
			attrs,
			!exact,
		)
	}

	managerStateKey := strings.Join([]string{"mig-config-state", base.RunID, string(node.UID)}, "/")
	previousState, stateExisted := c.state.ReplaceFingerprint(managerStateKey, state)
	if !stateExisted || previousState == state {
		return
	}
	var eventType string
	switch strings.ToLower(state) {
	case "pending", "rebooting":
		eventType = event.MIGReshapeStarted
	case "success":
		eventType = event.MIGReshapeFinished
	case "failed":
		eventType = event.MIGReshapeFailed
	default:
		return
	}
	observedAt := time.Now().UTC()
	stateBase := base
	stateBase.ClockType = event.ClockRealtime
	c.emitIfChanged(
		stateBase,
		eventType,
		previousState+"->"+state+"/"+profile+"/"+requestID,
		observedAt,
		mergeAttributes(common, map[string]any{
			"previous_mig_config_state": previousState,
			"precision":                 "mig-manager-node-label-observation",
			"note":                      "MIG Manager does not publish a transition timestamp on the Node label",
		}),
		true,
	)
}

func podDRAAttributes(state *State, pod *corev1.Pod) map[string]any {
	if len(pod.Spec.ResourceClaims) == 0 {
		return map[string]any{}
	}
	generated := map[string]string{}
	for _, status := range pod.Status.ResourceClaimStatuses {
		if status.ResourceClaimName != nil {
			generated[status.Name] = *status.ResourceClaimName
		}
	}
	claimNames := make([]string, 0, len(pod.Spec.ResourceClaims))
	claimUIDs := []string{}
	deviceClasses := []string{}
	deviceIDs := []string{}
	drivers := []string{}
	claimRefs := make([]map[string]any, 0, len(pod.Spec.ResourceClaims))
	for _, claim := range pod.Spec.ResourceClaims {
		actualName := ""
		templateName := ""
		if claim.ResourceClaimName != nil {
			actualName = *claim.ResourceClaimName
		}
		if claim.ResourceClaimTemplateName != nil {
			templateName = *claim.ResourceClaimTemplateName
			if actualName == "" {
				actualName = generated[claim.Name]
			}
		}
		claimRefs = append(claimRefs, map[string]any{
			"pod_claim_name":               claim.Name,
			"resource_claim_name":          actualName,
			"resource_claim_template_name": templateName,
		})
		if actualName == "" {
			continue
		}
		claimNames = append(claimNames, actualName)
		if metadata, ok := state.ResourceClaim(pod.Namespace, actualName); ok {
			claimUIDs = append(claimUIDs, metadata.UID)
			deviceClasses = append(deviceClasses, metadata.DeviceClasses...)
			deviceIDs = append(deviceIDs, metadata.DeviceIDs...)
			drivers = append(drivers, metadata.Drivers...)
		}
	}
	return map[string]any{
		"dra_claim_refs":       claimRefs,
		"resource_claim_names": uniqueSorted(claimNames),
		"resource_claim_uids":  uniqueSorted(claimUIDs),
		"dra_device_classes":   uniqueSorted(deviceClasses),
		"dra_device_ids":       uniqueSorted(deviceIDs),
		"dra_drivers":          uniqueSorted(drivers),
	}
}

func resourceClaimDeviceClasses(claim *unstructured.Unstructured) []string {
	requests, _, _ := unstructured.NestedSlice(claim.Object, "spec", "devices", "requests")
	classes := []string{}
	for _, raw := range requests {
		request, _ := raw.(map[string]any)
		if exactly, ok := request["exactly"].(map[string]any); ok {
			classes = append(classes, stringMapValue(exactly, "deviceClassName"))
		}
		// v1beta1 used the flat form. Retaining it here permits importing old
		// evidence, while the E09 runner itself requires resource.k8s.io/v1.
		classes = append(classes, stringMapValue(request, "deviceClassName"))
		if alternatives, ok := request["firstAvailable"].([]any); ok {
			for _, rawAlternative := range alternatives {
				alternative, _ := rawAlternative.(map[string]any)
				classes = append(classes, stringMapValue(alternative, "deviceClassName"))
			}
		}
	}
	return uniqueSorted(classes)
}

func resourceClaimAllocations(claim *unstructured.Unstructured) []draDeviceAllocation {
	results, _, _ := unstructured.NestedSlice(claim.Object, "status", "allocation", "devices", "results")
	allocations := make([]draDeviceAllocation, 0, len(results))
	for _, raw := range results {
		result, _ := raw.(map[string]any)
		allocation := draDeviceAllocation{
			Request: stringMapValue(result, "request"),
			Driver:  stringMapValue(result, "driver"),
			Pool:    stringMapValue(result, "pool"),
			Device:  stringMapValue(result, "device"),
			ShareID: stringMapValue(result, "shareID"),
		}
		if allocation.Driver == "" || allocation.Pool == "" || allocation.Device == "" {
			continue
		}
		allocations = append(allocations, allocation)
	}
	sort.Slice(allocations, func(i, j int) bool {
		return allocationDeviceID(allocations[i]) < allocationDeviceID(allocations[j])
	})
	return allocations
}

func resourceClaimConsumers(claim *unstructured.Unstructured) []draConsumer {
	reservedFor, _, _ := unstructured.NestedSlice(claim.Object, "status", "reservedFor")
	consumers := make([]draConsumer, 0, len(reservedFor))
	for _, raw := range reservedFor {
		value, _ := raw.(map[string]any)
		consumer := draConsumer{
			APIGroup: stringMapValue(value, "apiGroup"),
			Resource: stringMapValue(value, "resource"),
			Name:     stringMapValue(value, "name"),
			UID:      stringMapValue(value, "uid"),
		}
		if consumer.Resource == "" || consumer.Name == "" || consumer.UID == "" {
			continue
		}
		consumers = append(consumers, consumer)
	}
	sort.Slice(consumers, func(i, j int) bool { return consumers[i].UID < consumers[j].UID })
	return consumers
}

func singlePodConsumer(consumers []draConsumer) (draConsumer, bool) {
	var pod draConsumer
	found := false
	for _, consumer := range consumers {
		if consumer.Resource != "pods" || consumer.APIGroup != "" {
			continue
		}
		if found {
			return draConsumer{}, false
		}
		pod = consumer
		found = true
	}
	return pod, found
}

func resourceClaimDeviceStatuses(claim *unstructured.Unstructured) []any {
	statuses, _, _ := unstructured.NestedSlice(claim.Object, "status", "devices")
	return statuses
}

func resourceClaimPreparedAt(claim *unstructured.Unstructured, allocations []draDeviceAllocation) (time.Time, bool, bool) {
	if len(allocations) == 0 {
		return time.Time{}, false, false
	}
	statuses, _, _ := unstructured.NestedSlice(claim.Object, "status", "devices")
	readyAt := map[string]time.Time{}
	readyWithoutTime := map[string]bool{}
	for _, raw := range statuses {
		status, _ := raw.(map[string]any)
		allocation := draDeviceAllocation{
			Driver:  stringMapValue(status, "driver"),
			Pool:    stringMapValue(status, "pool"),
			Device:  stringMapValue(status, "device"),
			ShareID: stringMapValue(status, "shareID"),
		}
		conditions, _ := status["conditions"].([]any)
		for _, rawCondition := range conditions {
			condition, _ := rawCondition.(map[string]any)
			if stringMapValue(condition, "type") != "Ready" || stringMapValue(condition, "status") != "True" {
				continue
			}
			id := allocationDeviceID(allocation)
			at, exact := parseRFC3339Nano(stringMapValue(condition, "lastTransitionTime"))
			if exact {
				readyAt[id] = at
			} else {
				readyWithoutTime[id] = true
			}
		}
	}
	var latest time.Time
	exact := true
	for _, allocation := range allocations {
		id := allocationDeviceID(allocation)
		at, hasTimestamp := readyAt[id]
		if !hasTimestamp && !readyWithoutTime[id] {
			return time.Time{}, false, false
		}
		if !hasTimestamp {
			exact = false
			continue
		}
		if at.After(latest) {
			latest = at
		}
	}
	return latest, true, exact && !latest.IsZero()
}

func allocationDeviceID(allocation draDeviceAllocation) string {
	id := allocation.Driver + "/" + allocation.Pool + "/" + allocation.Device
	if allocation.ShareID != "" {
		id += "/" + allocation.ShareID
	}
	return id
}

func nestedTimestamp(object map[string]any, fields ...string) (time.Time, bool) {
	value, found, _ := unstructured.NestedString(object, fields...)
	if !found {
		return time.Time{}, false
	}
	return parseRFC3339Nano(value)
}

func annotationTimestamp(value string) (time.Time, bool) {
	return parseRFC3339Nano(value)
}

func parseRFC3339Nano(value string) (time.Time, bool) {
	at, err := time.Parse(time.RFC3339Nano, value)
	if err != nil || at.UnixNano() <= 0 {
		return time.Time{}, false
	}
	return at.UTC(), true
}

func opaqueConfigDrivers(config []any) []string {
	drivers := []string{}
	for _, raw := range config {
		value, _ := raw.(map[string]any)
		if opaque, ok := value["opaque"].(map[string]any); ok {
			drivers = append(drivers, stringMapValue(opaque, "driver"))
		}
	}
	return uniqueSorted(drivers)
}

func uniqueSorted(values []string) []string {
	seen := map[string]struct{}{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func stableFingerprint(value any) string {
	payload, err := json.Marshal(value)
	if err != nil {
		return fmt.Sprint(value)
	}
	return string(payload)
}
