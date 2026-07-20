# 架构说明

## 数据流

```text
Kubernetes API / optional CRDs ── hooke-controller ─┐
应用 / 负载器 / barrier ───────── Go SDK ───────────┤
ACK GOATScaler/SLS/ECS logs ─ hooke-ack-adapter ───┤
node health / future eBPF ─── hooke-node-agent ────┤
                                                    v
                                             hooke-ingester
                                                    |
                                                    v
                                                  MySQL
                                                    |
                                                    v
                                            hooke-correlator
                                                    |
                           pod_traces / layer_samples / metric_results
```

## 为什么不让采集器直接写 MySQL

统一通过 ingester 可以集中完成：

- 事件契约校验；
- 幂等 hash；
- 批量事务；
- 鉴权和限流；
- 存储故障隔离；
- 生产者重试。

两节点冒烟阶段不引入 Kafka。若后续事件量超过 MySQL 直接写入能力，可以把 `transport.Client` 的后端替换成 Kafka，而不改变采集器事件模型。

## 一致性

- 原子事件采用至少一次投递；
- MySQL 通过 `event_hash` 去重；
- 派生表按 `run_id` 重算并替换；
- 原始事件不会在重算时修改；
- `approximate` 和 `quality` 字段阻止近似口径与论文精确口径混用。

## 运行模式

### CPU 冒烟

Kubernetes Event 提供 Image Pull 近似起止，Pod Status 提供 Container Started，Pod Ready condition 提供 readiness 近似成功。所有替代事件显式标记近似。

### 精确论文口径

锁定 ACK 节点运行时后增加 eBPF：containerd Pull/Unpack、kubelet SyncPod。ACK Node 起点来自真实 GOATScaler/SLS/ECS 记录，不由程序推测或制造。
