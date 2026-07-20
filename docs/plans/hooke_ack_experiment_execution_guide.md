# Hooke ACK 复现实验执行手册

> 文档版本：v1.0  
> 编制日期：2026-07-18  
> 目标平台：阿里云 ACK 托管版，CPU 阶段  
> 起始规模：2 个固定 CPU Worker；另建真实弹性节点池，初始 `min=0`、冒烟阶段 `max=3`  
> 配套文档：`hooke_ack_metric_catalog.md`、`hooke_mysql_schema.sql`、`hooke_ack_cluster_creation_configuration_guide.md`  
> 原始论文：*Hooke: Diagnosing and Tuning Elasticity in Heterogeneous Kubernetes Clusters*

---

## 1. 这份手册解决什么问题

本文回答四个执行层问题：

1. 需要做哪些实验；
2. 应该先做哪个实验；
3. 第一轮冒烟怎样执行；
4. 冒烟通过后，怎样逐步扩展到 KEDA、Kueue、Argo 和更大节点规模。

正式实验不伪造节点、Pod、镜像或控制器事件。Node 层必须由真实 ACK 节点即时弹性触发，Image 层必须发生真实镜像检查或拉取，Pod 和 App 层必须由实际容器启动与 readiness 产生。

论文兼容的四层路径为：

```text
ℓ1 Node  : 节点供应任务创建 → Node Ready
ℓ2 Image : PullImage 开始 → 镜像拉取/解包完成
ℓ3 Pod   : kubelet SyncPod 开始 → Container Started
ℓ4 App   : Container Started → readiness 首次成功
```

ACK 环境中，论文里的 `NodeClaimCreated` 用真实 `ProvisionNode`/ACK GOATScaler 供应任务起点替代。

---

## 2. 从哪个实验开始

### 2.1 执行顺序

严格按以下顺序推进：

```text
S00 集群与时钟检查
  ↓
S01 采集器 → MySQL 数据链路冒烟
  ↓
S02 固定节点 Image/Pod/App 冒烟
  ↓
S03 ACK 真实节点扩容冒烟
  ↓
S04 轨迹关联与公式冒烟
  ↓
Gate-S：冒烟验收
  ↓
E01 四层基线矩阵
  ↓
E02 Node 供应与 warm-pool 对照
  ↓
E03 镜像冷/热缓存与并发拉取
  ↓
E04 KEDA scale-to-zero
  ↓
E05 Kueue Gang/部分准入
  ↓
E06 Argo Workflow 关键路径
  ↓
E07 端到端累计调优
  ↓
E08 采集器开销
  ↓
扩展到 8/16 个 CPU 节点
  ↓
E09 GPU/DRA/MIG（后续独立阶段）
```

### 2.2 第一轮只做什么

第一轮只做 `S00–S04`。目标不是得到论文级 p99，也不是证明调优收益，而是证明：

```text
一次真实 workload trigger
→ 能采到原子事件
→ 能写入 MySQL
→ 能按 UID/ID 拼成轨迹
→ 能计算非负、可追溯的层时延
→ 能真实触发 ACK 扩一个节点
```

第一轮建议准备 3–5 次固定节点运行和 3 次真实节点扩容运行。样本不用于发表统计结论。

---

## 3. 实验总览

| 编号 | 实验 | 是否需要新节点 | 是否需要 GPU | 主要回答的问题 |
|---|---|---:|---:|---|
| S00 | 集群与时钟检查 | 否 | 否 | 环境是否具备可重复实验条件 |
| S01 | 采集与 MySQL 链路冒烟 | 否 | 否 | 原子事件能否完整、幂等落库 |
| S02 | 固定节点 Image/Pod/App 冒烟 | 否 | 否 | 三层时间点能否被采集和关联 |
| S03 | ACK 真实 Node Provisioning 冒烟 | 是，真实扩 1 节点 | 否 | Pending → ProvisionNode → Node Ready 是否可恢复 |
| S04 | 轨迹与公式冒烟 | 复用 S01–S03 | 否 | 四层时延与弹性公式是否可重算 |
| E01 | 四层基线矩阵 | 部分 | 否 | 不同节点/缓存/应用状态的四层分布 |
| E02 | Node 与 warm pool | 是 | 否 | Node 是否为瓶颈，预热节点收益多大 |
| E03 | 镜像冷/热缓存与并发拉取 | 部分 | 否 | 镜像层受大小、缓存和并发影响多少 |
| E04 | KEDA scale-to-zero | 视容量而定 | 否 | `λ、μs、E[V]、τ` 与弹性的关系 |
| E05 | Kueue Gang | 是 | 否 | `k-out-of-n` 和 barrier 的影响 |
| E06 | Argo Workflow | 视容量而定 | 否 | 关键路径长度与工作流弹性的关系 |
| E07 | 累计调优 | 是 | 否 | 各 patch 的增量贡献 |
| E08 | 采集器开销 | 是 | 否 | CPU、内存、事件丢失和附加时延 |
| E09 | DRA/MIG | 是 | 是 | GPU reshape 代价与 DRA/MIG 选择 |

---

## 4. 冒烟环境与前置条件

### 4.1 集群拓扑

```text
ACK Managed Pro
│
├─ fixed-cpu-pool
│  ├─ 2 个固定 Worker
│  ├─ label: hooke.io/pool=fixed-cpu
│  └─ 运行采集控制面、MySQL 客户端、Prometheus agent 和固定节点实验
│
└─ elastic-cpu-pool
   ├─ Scaling Mode: Auto
   ├─ Min Instances: 0
   ├─ Max Instances: 3（正式实验前可调到 5）
   ├─ label: hooke.io/pool=elastic-cpu
   └─ taint: hooke.io/experiment=elastic:NoSchedule
```

弹性池必须在 ACK 节点池配置中预先定义 label 和 taint，不能等节点创建后再手工补。这样 GOATScaler 才能在节点尚不存在时判断待调度 Pod 能否由该节点池承载。

### 4.2 必须已具备

- ACK 节点即时弹性已经开启；
- `ACK GOATScaler` 组件为 `Installed`；
- GOATScaler 控制面日志已经采集到 SLS；
- 固定节点和弹性节点使用 containerd；
- 测试镜像已经推送到同地域 ACR，并记录 digest；
- MySQL 8.0+ 已执行 `hooke_mysql_schema.sql`；
- 最小采集代码已经实现：
  - `hooke-controller`：Pod、Node、Deployment、Event Watch；
  - `hooke-ingest`：事件校验、去重、写 MySQL；
  - `hooke-correlator`：至少能拼 Pod/Node/Container 的 MVP 轨迹；
- 论文级 Image/Pod 精确探针尚未完成时，可以先用 API/Event 近似口径冒烟，但必须把事件标记为 `approximate=true`，不能混入正式精确结果。

### 4.3 测试应用要求

准备一个 CPU 测试应用镜像，至少包含：

- `/livez`；
- `/readyz`；
- `/work`；
- 启动时打印 `process_start` 和 `ready`；
- 接收请求时生成 request ID；
- 可以配置真实 CPU 初始化工作量，例如读取配置、建立缓存或执行固定次数哈希计算；
- 镜像 tag 之外必须保存不可变 digest。

建议准备两个镜像变体：

| 镜像 | 用途 | 建议压缩大小 |
|---|---|---:|
| `hooke-smoke-small` | 快速功能冒烟 | 50–150 MB |
| `hooke-smoke-large` | Image 层验证 | 400–800 MB |

镜像大小通过真实镜像层形成，不在数据库中伪造拉取耗时。

---

## 5. 公共实验身份

每一次运行必须有唯一 `run_id`，推荐格式：

```text
<experiment>-<variant>-<UTC时间>-<4位随机串>
```

示例：

```text
S03-coldnode-20260718T083000Z-a7f2
```

所有实验对象都添加：

```yaml
metadata:
  labels:
    hooke.io/experiment: S03
    hooke.io/variant: coldnode
    hooke.io/run-id: S03-coldnode-20260718T083000Z-a7f2
```

每个 run 至少冻结：

- Git commit；
- Manifest SHA-256；
- Kubernetes、containerd、GOATScaler、CNI、CSI 版本；
- 节点池配置和实际 ECS 实例类型；
- ACR image digest；
- 可用区；
- SLO 秒数；
- collector 采样率；
- UTC 开始/结束时间。

---

# 第一轮冒烟

## 6. S00：集群、组件与时钟检查

### 6.1 目标

确认集群没有明显故障，并把不可变配置写入实验元数据。

### 6.2 步骤

#### 步骤 1：确认版本

```bash
kubectl version
kubectl get nodes -o custom-columns=NAME:.metadata.name,K8S:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion
```

#### 步骤 2：确认固定节点数量和标签

```bash
kubectl get nodes -L hooke.io/pool,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
```

预期：

- 当前只有 2 个固定 Worker；
- 两个节点均为 `hooke.io/pool=fixed-cpu`；
- 弹性节点池当前节点数为 0。

#### 步骤 3：确认核心组件

```bash
kubectl get pods -A -o wide
kubectl get --raw='/readyz?verbose'
```

必须确认：

- CoreDNS Ready；
- CNI Ready；
- CSI Ready；
- Prometheus 采集组件 Ready；
- Hooke controller/ingest/correlator Ready；
- 没有持续 CrashLoopBackOff 或 Pending 的系统 Pod。

#### 步骤 4：确认节点即时弹性

在 ACK 控制台确认：

- 节点伸缩已启用；
- 弹性池有 `Auto Scaling` 标记；
- `ACK GOATScaler` 已安装；
- GOATScaler 控制面日志可查询。

#### 步骤 5：确认 UTC 与时钟偏差

由 node-agent 每 10 秒写入：

```text
node_realtime_ns
node_monotonic_ns
collector_observed_ns
clock_offset_ns
```

冒烟阈值：

- 两个固定节点墙上时钟偏差绝对值建议 `< 100 ms`；
- API 事件时间和 collector observed time 的差值应被记录，不能覆盖源时间。

### 6.3 验收

| 检查项 | 通过条件 |
|---|---|
| 固定 Worker | 恰好 2 个且 Ready |
| 弹性池 | 配置存在，当前节点 0，min=0/max=3 |
| 运行时 | 所有节点均为 containerd |
| 系统组件 | 持续 5 分钟无重启增长 |
| 时钟 | 无明显漂移；偏移有记录 |
| 配置快照 | 已写入 `experiment_runs`/配置快照表 |

任一项失败，不进入 S01。

---

## 7. S01：采集器到 MySQL 的数据链路冒烟

### 7.1 目标

验证 Kubernetes 原子事件能够经过 Watch、标准化、去重和 ingest 后进入 MySQL。

### 7.2 步骤

1. 创建 run 记录，状态设为 `PREPARING`；
2. 在 `hooke-smoke` namespace 创建一个固定节点 Pod；
3. Pod 使用 small image，指定 `hooke.io/pool=fixed-cpu`；
4. 等待 Pod Ready；
5. 删除 Pod；
6. 查询 MySQL 原始事件；
7. 人为重启一次 watcher，验证 Watch 重连不会重复插入同一事件；
8. 将 run 状态改为 `SUCCEEDED` 或 `FAILED`。

示例 Pod：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fixed-smoke
  namespace: hooke-smoke
  labels:
    hooke.io/experiment: S01
    hooke.io/run-id: <RUN_ID>
spec:
  restartPolicy: Never
  nodeSelector:
    hooke.io/pool: fixed-cpu
  containers:
    - name: app
      image: <ACR_INTERNAL_IMAGE>@sha256:<DIGEST>
      ports:
        - containerPort: 8080
      readinessProbe:
        httpGet:
          path: /readyz
          port: 8080
        periodSeconds: 1
        timeoutSeconds: 1
        failureThreshold: 120
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          cpu: "1"
          memory: 1Gi
```

### 7.3 必须看到的原子事件

最少包括：

```text
RUN_STARTED
POD_CREATED
POD_SCHEDULED
CONTAINER_STARTED（MVP 可来自 Pod status）
POD_READY_CONDITION_TRUE
POD_DELETED
RUN_FINISHED
```

### 7.4 MySQL 检查示例

```sql
SELECT event_code, COUNT(*) AS n,
       MIN(event_time_ns) AS first_ns,
       MAX(event_time_ns) AS last_ns
FROM raw_events
WHERE run_id = ?
GROUP BY event_code
ORDER BY first_ns;
```

```sql
SELECT event_hash, COUNT(*) AS n
FROM raw_events
WHERE run_id = ?
GROUP BY event_hash
HAVING COUNT(*) > 1;
```

### 7.5 验收

- 事件按时间顺序可解释；
- `event_hash` 无重复；
- Pod UID、Node UID、container ID 均能落库；
- 删除 Pod 后历史事件仍保留；
- watcher 重启后没有新增重复事实；
- `observed_time_ns >= event_time_ns` 的异常若出现，必须有 clock-domain 解释，不能静默修正。

---

## 8. S02：固定节点 Image/Pod/App 冒烟

### 8.1 目标

在不扩节点的情况下验证 Image、Pod、App 三层。

### 8.2 运行设计

做两个变体，每个变体 3–5 次：

| 变体 | 节点 | 镜像 | 目的 |
|---|---|---|---|
| `fixed-cold-image` | 固定同一节点 | 该节点未出现过的新 digest | 真实触发镜像拉取 |
| `fixed-warm-image` | 固定同一节点 | 重复使用相同 digest | 验证 cache hit/跳过 Image 层 |

不要通过删除数据库记录或手工写事件制造“冷缓存”。冷缓存使用新的不可变 digest；热缓存使用同一 digest 并固定到同一目标节点。

### 8.3 步骤

1. 选定一个固定节点并为其添加临时实验标签：

```bash
kubectl label node <NODE_NAME> hooke.io/cache-target=s02 --overwrite
```

2. 创建 cold run；
3. 使用新 digest 启动应用；
4. 等待 readiness 和首个 `/work` 成功；
5. 删除 Pod，但保留节点和镜像缓存；
6. 创建 warm run，使用相同 digest 和相同目标节点；
7. 重复 3–5 轮；
8. 移除临时标签。

### 8.4 必须采集

MVP：

```text
POD_CREATED
POD_SCHEDULED
EVENT_PULLING
EVENT_PULLED
CONTAINER_STARTED
POD_READY_CONDITION_TRUE
FIRST_SUCCESS_RESPONSE
```

论文级探针完成后替换为：

```text
IMAGE_PULL_START
IMAGE_UNPACK_END
SYNC_POD_START
CONTAINER_STARTED
READINESS_PROBE_FIRST_SUCCESS
```

### 8.5 计算

```text
R_image_approx = EVENT_PULLED - EVENT_PULLING
R_pod_approx   = CONTAINER_STARTED - POD_SCHEDULED
R_app_approx   = POD_READY_CONDITION_TRUE - CONTAINER_STARTED
```

论文级：

```text
R_image = IMAGE_UNPACK_END - IMAGE_PULL_START
R_pod   = CONTAINER_STARTED - SYNC_POD_START
R_app   = READINESS_PROBE_FIRST_SUCCESS - CONTAINER_STARTED
```

### 8.6 验收

- cold run 出现真实 Pulling/Pulled 或精确 Pull 事件；
- warm run 被明确识别为 cache hit 或 Image 层不适用；
- 不允许仅因缺少 Pull 事件就自动判定 cache hit；
- 三层时延均为非负；
- end-to-end 与各已知阶段的差值被记录为 `unattributed_latency`。

---

## 9. S03：ACK 真实节点扩容冒烟

### 9.1 目标

真实触发一个 Pod Pending，并由 ACK GOATScaler 从 0 创建一个 ECS 节点，直至 Node Ready 和应用 Ready。

### 9.2 关键原则

- 不创建假 NodeClaim；
- 不直接向 MySQL 写供应时间；
- 不预先手工扩节点；
- 以弹性节点池的真实 `ProvisionNode`/供应任务作为 Node 层起点；
- 工作负载通过 nodeSelector 和 toleration 明确只允许落到弹性池。

### 9.3 示例 workload

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: elastic-smoke
  namespace: hooke-smoke
  labels:
    hooke.io/experiment: S03
    hooke.io/variant: real-node-scaleout
    hooke.io/run-id: <RUN_ID>
  annotations:
    goatscaler.io/safe-to-evict: "true"
spec:
  restartPolicy: Never
  nodeSelector:
    hooke.io/pool: elastic-cpu
  tolerations:
    - key: hooke.io/experiment
      operator: Equal
      value: elastic
      effect: NoSchedule
  containers:
    - name: app
      image: <ACR_INTERNAL_IMAGE>@sha256:<DIGEST>
      readinessProbe:
        httpGet:
          path: /readyz
          port: 8080
        periodSeconds: 1
        timeoutSeconds: 1
        failureThreshold: 300
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
        limits:
          cpu: "3"
          memory: 6Gi
```

资源 request 必须小于弹性池节点实际 Allocatable。不要用超出实例能力的请求来“强制扩容”，否则得到的是持续不可调度而不是正常供应。

### 9.4 步骤

1. 确认弹性池当前节点数为 0；
2. 创建 run，状态 `RUNNING`；
3. 提交上述 Pod；
4. 立即持续观察：

```bash
kubectl get pod -n hooke-smoke -w
kubectl get nodes -w
```

5. 查看 Pod 事件：

```bash
kubectl describe pod elastic-smoke -n hooke-smoke
kubectl get events -n hooke-smoke --sort-by=.metadata.creationTimestamp
```

6. 在 ACK/SLS 中确认 GOATScaler 供应任务；
7. 等待新 Node Ready；
8. 等待 Pod Scheduled、Container Started、Ready；
9. 调用 `/work` 并记录首次成功响应；
10. 删除 workload；
11. 清理或缩回弹性节点，使下一次 run 再次从 0 开始；
12. 重复 3 次。

### 9.5 必须恢复的链路

```text
WORKLOAD_TRIGGERED
→ POD_CREATED
→ POD_UNSCHEDULABLE
→ ACK_PROVISION_REQUESTED
→ ACK_PROVISION_TASK_CREATED
→ ECS_INSTANCE_CREATED
→ ECS_INSTANCE_RUNNING
→ NODE_CREATED
→ NODE_READY
→ POD_SCHEDULED
→ IMAGE_PULL_START/近似事件
→ CONTAINER_STARTED
→ READINESS 成功
→ FIRST_SUCCESS_RESPONSE
```

### 9.6 Node 计算

论文兼容：

```text
R_node = NODE_READY - ACK_PROVISION_TASK_CREATED
```

扩展诊断：

```text
R_decision       = ACK_PROVISION_TASK_CREATED - POD_UNSCHEDULABLE
R_cloud_create   = ECS_INSTANCE_RUNNING - ECS_INSTANCE_CREATED
R_join           = NODE_CREATED - ECS_INSTANCE_RUNNING
R_node_bootstrap = NODE_READY - NODE_CREATED
```

### 9.7 验收

- 真实新增至少 1 个 ECS/Node；
- `ProvisionNode`/task ID 能与 Pending Pod 关联；
- providerID 能映射 ECS instance ID；
- Node 层时延为非负；
- 新 Node 的 label/taint 与节点池模板一致；
- Pod 最终运行在该新增节点；
- 3 次 run 中至少 2 次形成完整轨迹；失败 run 也必须保留失败原因。

---

## 10. S04：轨迹关联与公式冒烟

### 10.1 目标

验证采集结果能被离线重算，而不是只显示在监控面板上。

### 10.2 步骤

1. 对 S01–S03 运行 correlator；
2. 以 `run_id + pod_uid + container_id + restart_count` 生成轨迹；
3. 对每层写入：
   - `applicable`；
   - `complete`；
   - `approximate`；
   - `start_event_id`；
   - `end_event_id`；
   - `duration_ns`；
4. 计算层弹性；
5. 生成一份 run 报告；
6. 任选一条轨迹，手工从 `raw_events` 重算并与结果表比对。

### 10.3 公式

对层 `ℓ` 的时延样本 `Rℓ`，SLO 为 `B` 秒：

```text
γ = 1 / B
E_l = (1/N) Σ exp(-γ × R_l)
```

适用层独立乘积：

```text
E_product = ∏ E_l
```

延迟占比和瓶颈分数：

```text
w_l = mean(R_l) / Σ mean(R_j)
bottleneck_l = w_l / E_l
```

### 10.4 验收

- 任一派生结果都能追溯到具体原子事件 ID；
- 不存在负时延；
- 不适用层和事件缺失层没有混为一类；
- 手工重算误差仅来自显示精度；
- 完整轨迹率达到冒烟门槛 `≥ 90%`；
- 结果报告包含未归因时延。

---

## 11. Gate-S：冒烟通过标准

全部满足才进入正式实验：

| 项目 | 门槛 |
|---|---:|
| 采集器与 ingest 可用性 | 连续 30 分钟无崩溃 |
| 原始事件写入成功率 | ≥ 99% |
| event hash 重复 | 0 |
| 固定节点轨迹完整率 | ≥ 95% |
| 真实扩节点轨迹完整率 | ≥ 80%，且失败可解释 |
| 负时延 | 0 |
| providerID ↔ ECS instance 映射 | 100% |
| 派生结果可追溯 | 100% |
| ACK 真实扩容 | 至少成功 2 次 |
| 系统组件异常 | 无持续 CrashLoop/Pending |

未达到门槛时，只修采集、关联或集群配置，不急着增加节点。

---

# 冒烟之后的正式实验

## 12. E01：四层基线矩阵

### 12.1 目标

建立 Node/Image/Pod/App 四层的基础分布，验证不同路径可以正确跳过或包含某些层。

### 12.2 因子

| 因子 | 水平 |
|---|---|
| 节点状态 | existing / newly-provisioned |
| 镜像状态 | warm / cold |
| 镜像大小 | small / large |
| 应用初始化 | light / heavy-real-work |
| 副本数 | 1 / 4 / 8 |

不建议第一轮做完整笛卡尔积。采用分阶段矩阵：

1. existing + warm + small + light；
2. existing + cold + large + light；
3. new + cold + small + light；
4. new + cold + large + heavy。

### 12.3 步骤

1. 冻结配置；
2. 为每个 cell 创建 variant；
3. 每个 cell 先做 5 次 pilot；
4. 数据质量通过后再做 30 次；
5. 每次 run 前验证节点、缓存和副本状态；
6. 随机化 cell 执行顺序，避免时间段和云库存造成系统性偏差；
7. 输出每层样本、p50/p95/p99、弹性和完整率。

### 12.4 主要输出

```text
R_node[], R_image[], R_pod[], R_app[]
E_node, E_image, E_pod, E_app
E_product
R_e2e
R_unattributed
```

---

## 13. E02：Node 供应与 warm-pool 对照

### 13.1 目标

验证论文 Rule 1 的方向：若 Node 层为主要瓶颈，预留一个可调度节点应显著降低端到端 scale-out 延迟。

### 13.2 变体

| 变体 | 弹性池配置 |
|---|---|
| cold-node | min=0，运行前确认节点数 0 |
| warm-node | min=1，运行前确认 1 个 Ready 且无实验 Pod |

### 13.3 步骤

1. 使用相同 workload、镜像 digest、资源 request；
2. cold-node 和 warm-node 随机交替运行；
3. cold-node 每次 run 前把实验池恢复到 0；
4. warm-node 每次 run 前确保预热节点 Ready；
5. 每个变体至少 30 次；
6. 按实际 instance type 和 zone 分层；
7. 比较 Node、e2e、p99 和弹性。

### 13.4 注意

ACK 新增节点可能存在最短保护时间，自动缩容不会立刻发生。清场可以等待平台缩容，也可以在测量结束后通过节点池管理执行真实删除；清场操作不纳入 scale-out 时延。

---

## 14. E03：镜像冷/热缓存与并发拉取

### 14.1 因子

| 因子 | 水平 |
|---|---|
| image size | 100 MB / 500 MB / 1 GB |
| cache | cold / warm |
| concurrent pulls per node | 1 / 2 / 4 |
| node | existing / new |

### 14.2 步骤

1. 所有镜像放在同地域 ACR；
2. cold 使用新 digest 或新节点；
3. warm 使用相同 digest 和相同节点；
4. 并发拉取必须保证 Pod 落在同一目标节点；
5. 记录 registry、下载字节、并发数、磁盘类型；
6. 分别计算下载和 unpack 子阶段；
7. 检查并发 pull 与 Image 时延是否相关。

---

## 15. E04：KEDA scale-to-zero

### 15.1 目标

从真实消息到达和冷启动样本得到：

```text
λ       到达率
μ_s     平均冷启动
E[V]    平均 busy period
τ       cooldownPeriod
τ*      满足目标弹性的最小 cooldown
```

### 15.2 推荐测试系统

CPU 冒烟阶段使用集群内 Redis list/stream：

```text
producer → Redis queue → KEDA ScaledObject → worker Deployment
```

避免第一轮引入 Kafka 的额外资源和启动噪声。

### 15.3 参数

| 参数 | Pilot | 正式 |
|---|---|---|
| λ | 1 req/s | 0.1、1、3 req/s |
| cooldown | 60、300 s | 30、60、140、300、600 s |
| minReplicaCount | 0 | 0 |
| maxReplicaCount | 4 | 8 或按容量 |
| 每 cell 重复 | 5 | ≥ 30 |

### 15.4 步骤

1. 确认副本已经缩到 0；
2. producer 写 `MESSAGE_ENQUEUED`；
3. KEDA 采样值和 active 状态持续采集；
4. 记录 HPA desired replica 变化；
5. 记录首 Pod Ready 和首消息处理成功；
6. 队列清空后记录 busy period 结束；
7. 等待 scale-to-zero；
8. 对每个 cooldown 重复；
9. 用原子事件计算模型并反解 `τ*`；
10. 用未参与拟合的 run 验证推荐值。

---

## 16. E05：Kueue Gang/部分准入

### 16.1 目标

验证 Gang 完成由第 `k` 个成员启动时间和应用 barrier 共同决定。

### 16.2 参数

| 参数 | Pilot | 扩节点后正式 |
|---|---|---|
| n | 2、4 | 2、4、8、16 |
| k | n、ceil(n/2) | n、ceil(n/2) |
| worker CPU | 250m | 250m–1 core |
| 重复 | 5 | ≥ 30 |

### 16.3 步骤

1. 配置 ResourceFlavor、ClusterQueue、LocalQueue；
2. 提交 suspend/queue-managed Batch Job；
3. 记录 Workload 创建、quota reserved、admitted、PodsReady；
4. 每个 worker 启动后进入真实 barrier；
5. 记录每个成员的 Ready rank；
6. 记录 barrier enter/exit；
7. 比较 `k=n` 和 `k=ceil(n/2)`；
8. 只对业务语义允许部分启动的 worker 使用较小 k。

### 16.4 输出

```text
R_(k:n)
B_n
η(n) = mean(exp(-γ B_n))
E_gang = E_(k:n) × η(n)
```

---

## 17. E06：Argo Workflow 关键路径

### 17.1 目标

验证关键路径阶段弹性乘积与直接测得的 Workflow 弹性之间的关系。

### 17.2 工作流

至少准备两版：

```text
Baseline:
A → B → C → D → E → F

Tuned:
      ┌→ B ─┐
A ────┤     ├→ D → E → F
      └→ C ─┘
```

B 与 C 必须没有真实数据依赖，不能仅根据 YAML 顺序推测。

### 17.3 步骤

1. 提交 Workflow；
2. Watch Workflow CR 和节点状态；
3. 记录阶段 startedAt、finishedAt、phase；
4. 记录 artifact ready 或业务数据完成事件；
5. 从 DAG 边计算 critical path；
6. 计算各阶段弹性乘积；
7. 比较 baseline/tuned；
8. 每版至少 30 次。

---

## 18. E07：端到端累计调优

### 18.1 变体顺序

```text
B0 baseline
B1 + warm node pool
B2 + KEDA τ*
B3 + Kueue k*
B4 + DAG parallelisation
```

每一步只增加一个变化，其他配置保持不变。

### 18.2 输出

| 变体 | E_e2e | p50 | p95 | p99 | trace complete | 主要瓶颈 |
|---|---:|---:|---:|---:|---:|---|
| B0 | | | | | | |
| B1 | | | | | | |
| B2 | | | | | | |
| B3 | | | | | | |
| B4 | | | | | | |

---

## 19. E08：采集器开销

### 19.1 模式

```text
collector-off
collector-on-10-percent
collector-on-100-percent
```

### 19.2 测量

- 每节点 collector CPU；
- 每节点内存；
- controller CPU/内存；
- ring buffer submitted/lost；
- ingest queue depth；
- event persistence latency；
- trace complete rate；
- 业务 Pod 启动分布；
- collector on/off 的 KS 检验和差值置信区间。

2 Worker 只做低速冒烟。达到 8/16 节点后再逐步提高 Pod starts/min。

---

## 20. 统一运行协议

### 20.1 运行前

1. 生成 `run_id`；
2. 冻结配置和 image digest；
3. 检查集群健康；
4. 确认前一 run 资源已清理；
5. 确认节点池期望状态；
6. 检查 MySQL 可写；
7. 检查 SLS/Prometheus 数据源；
8. 写 `RUN_STARTED`。

### 20.2 运行中

- 不人工修改 Pod 状态；
- 不手工插入原子事件；
- 允许只读观察；
- 任何紧急干预都写入 `operator_actions`；
- 超时、失败和资源不足必须保留。

### 20.3 运行后

1. 写 `RUN_FINISHED`；
2. 等待 10 分钟关联窗口或明确结束条件；
3. 运行 correlator；
4. 运行 calculator；
5. 生成数据质量报告；
6. 导出 manifest、版本和结果；
7. 清理 workload；
8. 恢复节点池到成本控制状态。

---

## 21. 样本量和统计策略

| 阶段 | 每 cell 建议样本 | 用途 |
|---|---:|---|
| 冒烟 | 3–5 | 功能正确性，不报告 p99 |
| Pilot | 5–10 | 发现方差和失败模式 |
| 正式均值/p50 | ≥ 30 | 基础比较 |
| p95 | ≥ 100 更稳妥 | 尾延迟 |
| p99 | ≥ 200，最好更多 | 论文级尾部结论 |

统计要求：

- 报告原始样本数、失败样本数和排除原因；
- p50/p95/p99 使用原始样本计算；
- 弹性报告 bootstrap 95% CI；
- 对 cold/warm、on/off 优先使用同一时间区组内的配对或交错运行；
- 若节点实例类型不同，分层报告，不直接混合。

---

## 22. 扩节点门槛

### Gate A：保持 2 Worker

只有 S00–S04 通过前，不增加固定节点。

### Gate B：扩到弹性 max=5

条件：

- 四层轨迹完整率达到目标；
- Node task 关联稳定；
- MySQL 无写入瓶颈；
- collector 100% 采样无明显丢失。

### Gate C：扩到 8 个 CPU 节点

用途：

- Kueue n=8/16；
- 并发拉取；
- 端到端调优；
- 中等速率开销实验。

### Gate D：扩到 16 个 CPU 节点

仅在需要更稳定 p95/p99 和更高 Pod 启动率时执行。

GPU 不属于 Gate D 的前置条件；GPU 是独立项目。

---

## 23. 失败处理

| 失败 | 处理 |
|---|---|
| GOATScaler 无法扩容 | 保留 `ProvisionNodeFailed`、库存和节点池配置；该 run 标记失败，不删 |
| 镜像拉取失败 | 保留 registry、digest、错误码和重试；不要把失败耗时混入成功样本 |
| Pod 被删除前未 Ready | 输出 partial trace，保留缺失位图 |
| Watch 重连 | 依赖 resourceVersion/event_hash 去重 |
| 时钟漂移 | 暂停正式实验；校准后重新运行，不离线“修漂亮” |
| 节点实例类型变化 | 按实际类型分层，必要时重跑固定类型池 |
| 采集器崩溃 | run 保留但不进入正式统计；先修复采集器 |

---

## 24. 每个实验的交付物

每个正式实验目录至少包含：

```text
<experiment>/<run_id>/
├─ run.json
├─ cluster-lock.yaml
├─ manifests/
├─ image-digests.txt
├─ raw-event-counts.csv
├─ trace-quality.json
├─ layer-samples.csv
├─ derived-metrics.json
├─ prometheus-snapshot-or-query.txt
├─ sls-query-reference.txt
└─ report.md
```

最终报告必须能够从 MySQL 原子数据重新生成。

---

## 25. 与代码开发的关系

| 能力 | 冒烟前必须 | 正式实验前必须 |
|---|---:|---:|
| Kubernetes Pod/Node/API Watch | 是 | 是 |
| MySQL ingest/幂等 | 是 | 是 |
| MVP correlator | 是 | 是 |
| ACK GOATScaler/SLS adapter | S03 前 | 是 |
| ECS OpenAPI adapter | 可在 S03 后补 | 是 |
| containerd 精确 Pull/Unpack 探针 | 否，可近似冒烟 | 是 |
| kubelet SyncPod/CRI 探针 | 否，可近似冒烟 | 是 |
| 应用 readiness/first-response 埋点 | S02 建议 | 是 |
| KEDA adapter | 否 | E04 前 |
| Kueue adapter/barrier 埋点 | 否 | E05 前 |
| Argo adapter | 否 | E06 前 |
| GPU adapter | 否 | E09 前 |

---

## 26. 官方参考文档索引

创建和配置时在官方站点按以下标题检索最新版本：

- 阿里云帮助中心：《Create an ACK managed cluster》
- 阿里云帮助中心：《ACK managed cluster: Parameters》
- 阿里云帮助中心：《Use node instant scaling to automatically scale nodes》
- 阿里云帮助中心：《Collect control plane component logs of ACK managed clusters》
- KEDA：《Deploying KEDA》《Scaling Deployments, StatefulSets & Custom Resources》
- Kueue：《Installation》及 Batch Job/Partial Admission 文档
- Argo Workflows：《Installation》《Field Reference》

