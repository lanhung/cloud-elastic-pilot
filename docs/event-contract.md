# 原子事件契约

## 必填字段

| 字段 | 说明 |
|---|---|
| `cluster_id` | ACK 集群稳定 ID |
| `run_id` | ULID 格式实验运行 ID |
| `event_type` | 大写事件编码 |
| `event_time_ns` | 事件发生的 Epoch 纳秒 |
| `source_component` | 事件生产者 |

Ingester 补齐：`event_id`、`observed_time_ns`、`event_hash`。

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

## ACK 事件

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
