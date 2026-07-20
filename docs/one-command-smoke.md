# 一键执行 ACK 第一轮冒烟

脚本采用混合部署：测试工作负载运行在 ACK；`hooke-controller`、`hooke-ingester`、MySQL、关联器和计算器运行在本地 Linux 工作电脑。ACK 不需要访问本地 MySQL，也不需要把 kubeconfig 上传到集群。

```text
ACK API Server ── kubeconfig ──> 本地 hooke-controller
                                      │
                                      ▼
                              本地 hooke-ingester
                                      │
                                      ▼
                                  本地 MySQL
```

## 1. 准备配置

```bash
cd hooke-ack-reproducer
cp configs/smoke.env.example configs/smoke.env
chmod 600 configs/smoke.env
$EDITOR configs/smoke.env
```

至少确认：

```bash
KUBECONFIG_PATH="$HOME/.kube/config"
KUBE_CONTEXT="你的 ACK context"
EXPECTED_API_SERVER_SUBSTRING="可选：API Server 域名片段"
CONFIRM_KUBE_CONTEXT="yes"
CLUSTER_ID="你的实验集群标识"
SMOKE_IMAGE="同地域 ACR 中可访问的 HTTP 镜像"
```

默认镜像需要满足：监听 `SMOKE_CONTAINER_PORT`，且访问 `SMOKE_READINESS_PATH` 返回 2xx/3xx。中国地域建议使用同地域 ACR 中固定 tag 或 digest 的镜像。

## 2. 只做预检

```bash
./scripts/ack-first-smoke.sh \
  --config configs/smoke.env \
  --check-only
```

预检只检查 kubeconfig、context、ACK API Server、RBAC、Docker、Go 等，不创建本地服务或 ACK 工作负载。脚本要求先将 `CONFIRM_KUBE_CONTEXT` 改为 `yes`，避免误操作其他集群。

也可以运行：

```bash
make smoke-ack-check
```

## 3. 一步执行固定节点冒烟

```bash
./scripts/ack-first-smoke.sh --config configs/smoke.env
```

或：

```bash
make smoke-ack
```

默认流程：

1. 启动或复用本地 MySQL 8.4 容器；
2. 构建 migration、ingester、controller、hookectl 等二进制；
3. 执行数据库迁移；
4. 创建唯一实验 `run_id`；
5. 本地 controller 使用 kubeconfig Watch ACK；
6. 在实验 namespace 中做 3 次真实 `Deployment 0 → 1 → 0`；
7. 使用本地 `kubectl port-forward` 验证 HTTP 服务；
8. 停止采集，构建 Pod/Container 轨迹；
9. 计算层时延和弹性指标；
10. 执行 Gate-S，并导出事件、轨迹、指标和日志。

脚本不会生成、补写或模拟 Node、ECS、NodeClaim 事件。

## 4. 输出目录

```text
artifacts/first-smoke-<UTC时间>/
├── summary.md
├── run.json
├── events.tsv
├── traces.tsv
├── metrics.tsv
├── trace-quality.tsv
├── calculation.json
├── report.json
├── controller.log
├── ingester.log
├── kubernetes-version.yaml
├── nodes-initial.txt
└── 本轮生成的 Kubernetes YAML 与排障信息
```

成功时 `summary.md` 显示：

```text
result: PASS
```

MySQL 容器和 volume 默认保留，便于继续查询：

```bash
docker exec -it hooke-smoke-mysql \
  mysql -uhooke -phooke hooke
```

## 5. 默认 Gate-S

至少要求每轮固定节点实验采集到：

```text
POD_CREATED
POD_SCHEDULED
CONTAINER_STARTED
POD_READY
READINESS_PROBE_FIRST_SUCCESS
```

并要求：

- 完整轨迹数量不少于 `SMOKE_REPETITIONS`；
- Pod 层样本数量不少于 `SMOKE_REPETITIONS`；
- App 层样本数量不少于 `SMOKE_REPETITIONS`；
- 派生结果能够按 `run_id` 追溯至原始事件。

第一轮没有 eBPF，因此：

- Image Pull 来自 Kubernetes Event，属于近似口径；
- Pod 层起点使用 `POD_SCHEDULED` 代理 `SyncPod`；
- App 层终点使用 Pod Ready Condition 代理首次 readiness 成功。

这些样本用于验证链路和公式，不应标记为论文的精确 eBPF 口径。

## 6. 可选：真实 ACK 节点扩容冒烟

先在 ACK 中准备：

```text
弹性节点池 min=0
唯一 label，例如 hooke.io/pool=elastic
可选 taint，例如 hooke.io/experiment=true:NoSchedule
ACK 节点即时弹性/GOATScaler 已启用
```

配置：

```bash
ENABLE_NODE_SCALE_SMOKE="true"
ELASTIC_NODE_SELECTOR_KEY="hooke.io/pool"
ELASTIC_NODE_SELECTOR_VALUE="elastic"
ELASTIC_TAINT_KEY="hooke.io/experiment"
ELASTIC_TAINT_VALUE="true"
ELASTIC_TAINT_EFFECT="NoSchedule"
```

脚本会：

1. 确认开始前没有匹配该 selector 的节点；
2. 临时设置 `hooke-system/hooke-active-run`；
3. 创建只能调度到弹性池的真实 Pod；
4. 等待 ACK 新建 ECS/Node 并使 Pod Ready；
5. 比较扩容前后的 Node 名称；
6. 清空 active run，并缩容测试 Deployment。

没有 `ACK_EVENTS_NDJSON` 时，Node 层只能使用：

```text
POD_UNSCHEDULABLE → NODE_READY
```

这是扩展近似口径。将真实 GOATScaler/SLS 日志导出为 NDJSON，并按日志字段调整 `configs/ack-adapter.yaml` 后，可设置：

```bash
ACK_EVENTS_NDJSON="/absolute/path/goatscaler.ndjson"
ACK_ADAPTER_CONFIG="configs/ack-adapter.yaml"
```

脚本会导入 `ACK_PROVISION_TASK_CREATED` 等真实事件。

## 7. 使用外部 MySQL

```bash
MYSQL_MODE="external"
MYSQL_DSN='user:password@tcp(host:3306)/hooke?parseTime=true&loc=UTC&multiStatements=true'
MYSQL_CLI_HOST="host"
MYSQL_CLI_PORT="3306"
MYSQL_CLI_USER="user"
MYSQL_CLI_PASSWORD="password"
MYSQL_DATABASE="hooke"
```

Go 服务使用 `MYSQL_DSN`，自动 Gate-S 查询使用本机 `mysql` CLI 参数。

## 8. 清理与安全

默认行为：

- 成功后删除本轮 Deployment/Service；
- 每轮使用带 UTC 时间戳的独立实验 namespace，避免历史 Kubernetes Event 污染新 Run；
- 默认删除本轮独立 namespace；
- 失败时保留 ACK 工作负载供排障；
- 不删除本地 MySQL 数据；
- 不复制或上传 kubeconfig；
- 不在产物目录保存明文 Token、DSN 或密码。

需要重建测试数据库时才设置：

```bash
RESET_MYSQL="true"
```

该选项会删除 `MYSQL_CONTAINER_NAME` 和 `MYSQL_VOLUME_NAME`，数据不可恢复。

如需复用预先创建的 namespace，必须同时设置：

```bash
UNIQUE_EXPERIMENT_NAMESPACE="false"
DELETE_EXPERIMENT_NAMESPACE="false"
```

复用 namespace 时，仍在 Kubernetes Event TTL 内的旧 Pod Event 可能被 informer
初始列表重新归入新 Run，因此不建议用于需要干净原始产物的实验。
