package event

const (
	ExperimentStarted = "EXPERIMENT_STARTED"
	ExperimentStopped = "EXPERIMENT_STOPPED"

	DeploymentDesiredReplicasChanged = "DEPLOYMENT_DESIRED_REPLICAS_CHANGED"
	HPADesiredReplicasChanged        = "HPA_DESIRED_REPLICAS_CHANGED"

	PodCreated       = "POD_CREATED"
	PodScheduled     = "POD_SCHEDULED"
	PodUnschedulable = "POD_UNSCHEDULABLE"
	PodInitialized   = "POD_INITIALIZED"
	PodReady         = "POD_READY"
	PodDeleted       = "POD_DELETED"

	ImagePullStart   = "IMAGE_PULL_START"
	ImagePullEnd     = "IMAGE_PULL_END"
	ImagePullFail    = "IMAGE_PULL_FAILED"
	ImageUnpackStart = "IMAGE_UNPACK_START"
	ImageUnpackEnd   = "IMAGE_UNPACK_END"
	ImageUnpackFail  = "IMAGE_UNPACK_FAILED"
	ImageCacheHit    = "IMAGE_CACHE_HIT"

	SyncPodStart     = "SYNC_POD_START"
	PodSandboxStart  = "POD_SANDBOX_START"
	PodSandboxEnd    = "POD_SANDBOX_END"
	PodSandboxFail   = "POD_SANDBOX_FAILED"
	CNISetupStart    = "CNI_SETUP_START"
	CNISetupEnd      = "CNI_SETUP_END"
	CNISetupFail     = "CNI_SETUP_FAILED"
	ContainerStarted = "CONTAINER_STARTED"
	ContainerStopped = "CONTAINER_STOPPED"

	ReadinessProbeFirstSuccess = "READINESS_PROBE_FIRST_SUCCESS"
	ApplicationListening       = "APPLICATION_LISTENING"
	FirstRequestReceived       = "FIRST_REQUEST_RECEIVED"
	FirstSuccessfulResponse    = "FIRST_SUCCESSFUL_RESPONSE"
	WarmupFinished             = "WARMUP_FINISHED"

	ACKProvisionTaskCreated = "ACK_PROVISION_TASK_CREATED"
	ACKProvisionTaskUpdated = "ACK_PROVISION_TASK_UPDATED"
	ACKProvisionRequested   = "ACK_PROVISION_REQUESTED"
	ACKProvisionFailed      = "ACK_PROVISION_FAILED"
	ECSInstanceCreated      = "ECS_INSTANCE_CREATED"
	ECSInstanceRunning      = "ECS_INSTANCE_RUNNING"
	NodeCreated             = "NODE_CREATED"
	NodeReady               = "NODE_READY"
	NodeNotReady            = "NODE_NOT_READY"

	KEDAScaledObjectCreated  = "KEDA_SCALEDOBJECT_CREATED"
	KEDAScaledObjectActive   = "KEDA_SCALEDOBJECT_ACTIVE"
	KEDAScaledObjectInactive = "KEDA_SCALEDOBJECT_INACTIVE"
	KEDAScaledObjectReady    = "KEDA_SCALEDOBJECT_READY"
	KEDAScalerSample         = "KEDA_SCALER_SAMPLE"
	KEDAScaleToZero          = "KEDA_SCALE_TO_ZERO"
	MessageEnqueued          = "MESSAGE_ENQUEUED"
	MessageDequeued          = "MESSAGE_DEQUEUED"
	MessageProcessingStarted = "MESSAGE_PROCESSING_STARTED"
	MessageProcessed         = "MESSAGE_PROCESSED"
	QueueMessageArrived      = "QUEUE_MESSAGE_ARRIVED"
	QueueDepthSample         = "QUEUE_DEPTH_SAMPLE"
	BusyPeriodStarted        = "BUSY_PERIOD_STARTED"
	BusyPeriodEnded          = "BUSY_PERIOD_ENDED"

	KueueWorkloadCreated       = "KUEUE_WORKLOAD_CREATED"
	KueueQuotaReserved         = "KUEUE_QUOTA_RESERVED"
	KueueWorkloadAdmitted      = "KUEUE_WORKLOAD_ADMITTED"
	KueueSchedulingGateRemoved = "KUEUE_SCHEDULING_GATE_REMOVED"
	KueuePodsReady             = "KUEUE_PODS_READY"

	ACKQueueUnitCreated     = "ACK_QUEUE_UNIT_CREATED"
	ACKQueueUnitEnqueued    = "ACK_QUEUE_UNIT_ENQUEUED"
	ACKQueueUnitReserved    = "ACK_QUEUE_UNIT_RESERVED"
	ACKQueueUnitDequeued    = "ACK_QUEUE_UNIT_DEQUEUED"
	ACKQueueUnitRunning     = "ACK_QUEUE_UNIT_RUNNING"
	ACKQueueUnitFinished    = "ACK_QUEUE_UNIT_FINISHED"
	ACKQueueUnitFailed      = "ACK_QUEUE_UNIT_FAILED"
	ACKQueuePodStateChanged = "ACK_QUEUE_POD_STATE_CHANGED"
	ACKQueueAllPodsRunning  = "ACK_QUEUE_ALL_PODS_RUNNING"
	ACKQueueJobUnsuspended  = "ACK_QUEUE_JOB_UNSUSPENDED"
	ACKQueueJobFinished     = "ACK_QUEUE_JOB_FINISHED"
	ACKQueueJobFailed       = "ACK_QUEUE_JOB_FAILED"

	GangBarrierEnter   = "GANG_BARRIER_ENTER"
	GangBarrierExit    = "GANG_BARRIER_EXIT"
	UsefulWorkStarted  = "USEFUL_WORK_STARTED"
	UsefulWorkFinished = "USEFUL_WORK_FINISHED"

	ArgoWorkflowCreated  = "ARGO_WORKFLOW_CREATED"
	ArgoWorkflowStarted  = "ARGO_WORKFLOW_STARTED"
	ArgoWorkflowFinished = "ARGO_WORKFLOW_FINISHED"
	ArgoStageStarted     = "ARGO_STAGE_STARTED"
	ArgoStageFinished    = "ARGO_STAGE_FINISHED"
	ArgoWorkflowEdge     = "ARGO_WORKFLOW_EDGE"
	ArtifactInputReady   = "ARTIFACT_INPUT_READY"
	ArtifactOutputReady  = "ARTIFACT_OUTPUT_READY"

	ResourceSupplySample = "RESOURCE_SUPPLY_SAMPLE"
	ResourceDemandSample = "RESOURCE_DEMAND_SAMPLE"

	DRADeviceClassAvailable   = "DRA_DEVICECLASS_AVAILABLE"
	DRAResourceSlicePublished = "DRA_RESOURCESLICE_PUBLISHED"
	DRAResourceClaimCreated   = "RESOURCE_CLAIM_CREATED"
	DRAResourceClaimAllocated = "RESOURCE_CLAIM_ALLOCATED"
	DRAResourceClaimReserved  = "RESOURCE_CLAIM_RESERVED"
	DRAResourceClaimPrepared  = "RESOURCE_CLAIM_PREPARED"
	MIGReshapeRequested       = "MIG_RESHAPE_REQUESTED"
	MIGReshapeStarted         = "MIG_RESHAPE_STARTED"
	MIGReshapeFinished        = "MIG_RESHAPE_FINISHED"
	MIGReshapeFailed          = "MIG_RESHAPE_FAILED"
	FirstCUDASuccess          = "FIRST_CUDA_SUCCESS"

	// Deprecated aliases keep callers built against the initial GPU formula
	// prototype source-compatible. New producers must emit the canonical E09
	// event names above so the stored contract matches the metric catalog.
	GPUReshapeRequested       = MIGReshapeRequested
	GPUReconfigurationStarted = MIGReshapeStarted
	GPUReconfigurationEnded   = MIGReshapeFinished
	GPUFirstOperationSuccess  = FirstCUDASuccess

	CollectorHealth = "COLLECTOR_HEALTH"
	ClockSyncSample = "CLOCK_SYNC_SAMPLE"
)
