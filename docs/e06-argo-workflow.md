# E06：ACK Argo Workflow 关键路径冒烟

## 1. 范围

E06 当前只执行一个随机顺序的串行/并行配对冒烟，用于验证 ACK Argo Workflow
控制面、Hooke 原子事件、业务真实依赖、DAG 关键路径和报告链路。它不是每版至少
30 次的正式 Pilot，不输出稳定的 p50/p95/p99 或论文结论。

2026-07-27 的 ACK 1×2 冒烟已 2/2 PASS，结果见
[`result/e06-argo-workflow-smoke-20260727.md`](result/e06-argo-workflow-smoke-20260727.md)。

两版工作流为：

```text
baseline: A → B → C → D → E → F

tuned:          ┌→ B ─┐
           A ───┤     ├→ D → E → F
                └→ C ─┘
```

B 和 C 都只消费 A 的业务输出，彼此不存在真实数据或副作用依赖。两版 Workflow
保存完全相同的 `hooke.io/true-dependencies` 注解；baseline 的 `B→C` 只是用于
构造串行对照的控制边。runner 同时冻结 `hooke.io/control-dependencies`，不会从
YAML 顺序猜测业务依赖。

默认阶段持续时间为 `A=2s,B=6s,C=4s,D=2s,E=1s,F=1s`。B 明确长于 C，因此 tuned
关键路径必须稳定为 `A→B→D→E→F`，而不是依赖 map 遍历或时间相等时的偶然选择。

## 2. ACK 前置条件

- ACK Kubernetes API Ready；
- 已安装 `ack-workflow` Chart 3.5.15；
- `workflows.argoproj.io` 和 `workflowtaskresults.argoproj.io` CRD Established；
- workflow-controller 全副本 Available，实际镜像版本前缀与配置一致；
- 精确 node selector 只匹配一个物理 Ready 节点；
- 节点无 Memory/Disk/PID/NTP 异常及未容忍的阻断 taint；
- 节点按 Kubernetes requests 计算的空闲资源至少满足配置门槛；
- 同 Region ACR 中已有从干净提交构建的不可变 E06 worker 镜像。

当前 ACK Argo 安装没有启用持久化和 artifact repository。E06 冒烟不使用
Artifact/PVC，而以应用 source timestamp 日志证明阶段有效工作边界，因此不受该
限制。后续若测 artifact ready，必须单独配置对象存储并增加 A2 事件，不能把
Workflow YAML 依赖当作 artifact 可读时间。

## 3. 构建和配置

先提交 E06 适配代码，再构建并推送镜像。推送脚本拒绝 dirty worktree，并把提交、
平台、本地 image ID 和不可变 repository digest 写入被 Git 忽略的 metadata：

```bash
cp configs/argo-workflow.env.example configs/argo-workflow.env
$EDITOR configs/argo-workflow.env

make e06-image-push \
  IMAGE_REPOSITORY=<same-region-acr-repository>
```

把 `dist/e06-image.env` 中的 `E06_APP_IMAGE` 复制到配置。固定节点必须使用真实
`kubernetes.io/hostname`；不要选择带 `type=virtual-kubelet` 的节点。

## 4. 只读预检

```bash
make e06-ack-check
```

预检不创建 Kubernetes 资源。它会校验：

1. kube context 和 API Server 双重确认；
2. Git 状态、镜像构建提交、digest 与构建输入未漂移；
3. Helm release、Chart、controller 镜像和 CRD；
4. 当前身份和 controller ServiceAccount 权限；
5. 固定节点唯一性、压力/NTP/taint 和 scheduler headroom；
6. 集群级 E06 Lease 不存在。

ACK Chart 在 `argo` Namespace 为默认 ServiceAccount 提供 executor Role，但该
RoleBinding 不会自动出现在新 Namespace。正式执行时 runner 会在隔离 Namespace
创建专用 ServiceAccount，以及仅允许
`workflowtaskresults.argoproj.io create/patch` 的最小 Role/RoleBinding。

## 5. 执行

```bash
CONFIRM_E06_EXECUTION=yes make e06-ack
```

执行顺序：

1. 创建集群级 Lease 和带 `hooke.io/run-id` 的隔离 Namespace；
2. 创建最小 executor RBAC；
3. 在固定节点运行一次 100ms worker，证明不可变镜像可拉取并预热缓存；
4. 按 seed 随机执行 baseline/tuned；
5. 每 0.5 秒保存 Workflow CR 和 Pod 快照；
6. 保存最终 CR、Pod、main container 日志；
7. 从日志导出精确应用事件；
8. 重建控制边、真实依赖、stage eligible 时间和关键路径；
9. 生成 cell summary、配对汇总和 Markdown 报告；
10. 按清理配置删除实验 Namespace 和 Lease。

固定节点每个 cell 前都会重新检查，防止 `min=0` 的 GOATScaler 节点在两次运行间
消失。E06 不修改节点池 min/max，也不把节点扩容时延混入 DAG 对照。

## 6. 冒烟 Gate

每个 cell 必须同时满足：

- Workflow phase 为 `Succeeded`；
- A–F 恰好各有一个 `type=Pod` 的 Argo node，不允许 retry/duplicate；
- 六个 Pod 全部成功、绑定精确 Workflow UID、固定到目标节点；
- main container 实际 imageID 匹配配置的不可变 digest；
- 12/12 `USEFUL_WORK_STARTED/FINISHED` 为 application log source timestamp；
- 业务真实依赖注解未漂移，B/C 不互相依赖；
- baseline B/C 不重叠，tuned B/C 必须真实重叠；
- baseline 关键路径为六阶段，tuned 为五阶段；
- 每个配对中 tuned Workflow 端到端时间必须短于 baseline。

派生量同时保存：

```text
stage_duration = ARGO_STAGE_FINISHED - ARGO_STAGE_STARTED
stage_startup_delay = USEFUL_WORK_STARTED - stage_eligible_time
critical_path = DAG 上累计 stage_duration 最大路径
E_wf_predicted = Π exp(-stage_duration / B_slo), stage ∈ critical_path
E_wf_measured = exp(-workflow_duration / B_slo)
model_error = |E_wf_measured - E_wf_predicted|
```

这些单样本数值只用于证明计算链可运行，不解释为稳定收益。

## 7. Artifact

默认输出目录为：

```text
artifacts/e06-argo-workflow-smoke-<UTC>-<suffix>/
├── run-metadata.json
├── argo-helm-release.json
├── target-node-before.json
├── warmup-pod.json
├── schedule.tsv
├── cells/
│   └── <sequence>-<variant>/
│       ├── manifest.json
│       ├── workflow-snapshots.ndjson
│       ├── pod-snapshots.ndjson
│       ├── workflow.json
│       ├── pods.json
│       ├── application-events.ndjson
│       ├── logs/
│       └── summary.json
├── summary.json
├── summary.tsv
└── report.md
```

失败时若 `CLEANUP_K8S_ON_ERROR=false`，runner 会保留 Namespace 供诊断；否则仍保留
本地 artifact，但删除实验 Kubernetes 资源。
