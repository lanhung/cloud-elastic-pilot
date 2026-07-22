# 原子事件契约

## 必填字段

| 字段 | 说明 |
|---|---|
| `cluster_id` | ACK 集群稳定 ID |
| `run_id` | ULID 格式实验运行 ID |
| `event_type` | 大写事件编码 |
| `source_time_ns` | 生产者原始时钟的 Epoch 纳秒 |
| `event_time_ns` | 校正后用于排序的 UTC Epoch 纳秒 |
| `source_component` | 事件生产者 |

生产者补齐 `observed_time_ns`；Ingester 覆盖写入 `ingest_time_ns`，并补齐
`event_id`、`event_hash`。若有真实时钟测量，则：

```text
event_time_ns = source_time_ns + clock_offset_ns
```

`clock_offset_ns` 和 `clock_uncertainty_ns` 未知时必须留空，不能用零冒充。
已接收事件的校正时间不可原地修改。

## 关联字段

优先级：

1. `pod_uid`
2. `container_id`
3. `node_uid`
4. `workload_uid`
5. 名称字段

不能用 Pod 名称代替 Pod UID，因为重建后同名 Pod 是另一实体。

## 精度

```json
{
  "approximate": true,
  "attributes": {
    "precision": "kubernetes-event",
    "note": "Pulling/Pulled event, not containerd uprobe"
  }
}
```

近似事件可以用于冒烟和链路校验，但正式论文精度报告必须单独过滤或分组。

正式 E01 的 containerd/kubelet/CRI 导出应先规范化为 NDJSON，再使用：

```bash
hookectl events import --api URL --cluster ID --run-id ID --file runtime.ndjson
```

导入器拒绝缺少真实 `event_time_ns` 或混入其他 cluster/run 的记录。

当前 ACK E01 导出器 `scripts/export-runtime-journal-events.py` 使用节点上
containerd CRI 日志内嵌的 RFC3339Nano 时间，按 Pod UID、sandbox ID 和
container ID 关联并产生精确的 `POD_SANDBOX_START/END`、
`IMAGE_PULL_START/END` 与 `CONTAINER_STARTED`。热缓存不是由“没有 Pull”
反推，而是必须匹配 kubelet 对指定 Pod、容器和 digest 的明确
`already present on machine` 记录，才产生 `IMAGE_CACHE_HIT`。原始筛选日志
保存在运行 artifact 的 `runtime-journal/` 中。

Kubernetes `containerStatuses[].state.running.startedAt` 仅作为
`precision=pod-status-second-resolution` 的近似后备信号。只要同一容器存在
精确 CRI `StartContainer` 记录，关联器必须优先选择 CRI 边界，即使它在秒级
PodStatus 时间之后；不能因“最早时间优先”让粗粒度后备值覆盖精确值。

应用层的日志模式由应用进程在生命周期边界写入 `source_time_ns`，runner
在 Pod 销毁前保存结构化 stdout；同一导出器校验 cluster、run、Pod UID、
节点、容器及实验时间窗后产生 `source_component=application-event-log` 的
精确事件。这里的 stdout 是事件载体，不是用日志采集时间代替事件发生时间。

ACK 默认 info 级日志未提供可按 Pod UID 独立配对的 CNI start/end。导出器
因此不生成 CNI 事件；只有接入真实 CNI 事件源后才能开启 CNI 子阶段 Gate。

## ACK 事件

Kubernetes watcher 直接保存以下官方关联字段，但只复制白名单字段，不保存完整 annotation/label map：

| 对象 | 原始字段 | `attributes` 字段 |
|---|---|---|
| Pod | `goatscaler.io/provision-task-id` | `task_id` |
| Pod | `goatscaler.io/provision-node-name` | `provision_node_name` |
| Node | `goatscaler.io/provision-task-id` | `task_id` |
| Node | `spec.providerID` | `provider_id` |
| Event | `metadata.uid` | `kubernetes_event_uid` |
| Event | `involvedObject.uid` | `involved_object_uid` |

Pod annotation 或 Node label 首次可见时生成
`ACK_PROVISION_TASK_UPDATED`，并分别标记
`precision=goatscaler-pod-annotation` 或
`precision=goatscaler-node-label`。Kubernetes Event 的 `ProvisionNode`、
`ProvisionNodeFailed`、`ResetPod` 分别规范化为
`ACK_PROVISION_REQUESTED`、`ACK_PROVISION_FAILED`、
`ACK_PROVISION_TASK_UPDATED`。这些 Event 的时间属于 Kubernetes Event
口径，不能冒充 SLS 中严格的任务创建时间。

`hooke-ack-adapter` 不臆测 ACK 日志字段。它通过 YAML 中的字段路径和正则规则读取真实记录。规范化后的最小示例：

```json
{
  "action": "CreateNode",
  "event_time": "2026-07-18T08:00:00.123456Z",
  "run_id": "01J...",
  "task_id": "task-123",
  "instance_id": "i-123",
  "node_name": "cn-hangzhou.10.0.0.10",
  "pending_pod_uids": ["uid-a", "uid-b"]
}
```

字段名可以通过配置替换，不要求 ACK 原始日志长成这个样子。
