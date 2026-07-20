# 第一轮 CPU 冒烟运行手册

第一轮目标不是得到论文最终数值，而是证明：真实事件能进入数据库、能够关联、能够计算，并且近似事件不会冒充精确事件。

## 0. 前置条件

- ACK 两个固定 CPU Worker；
- 一个 `min=0/max=3` 的弹性 CPU 节点池；
- RDS MySQL 8.0+ 或测试 MySQL；
- ACR 中已经推送工程镜像和 smoke-app 镜像；
- 集群、节点和容器运行时版本已记录；
- 所有节点使用 UTC/NTP。

## 1. 创建数据库 Secret

```bash
kubectl create namespace hooke-system
kubectl -n hooke-system create secret generic hooke-mysql \
  --from-literal=dsn='USER:PASSWORD@tcp(HOST:3306)/hooke?parseTime=true&loc=UTC&multiStatements=true'
```

## 2. 安装工程

```bash
helm upgrade --install hooke deploy/helm/hooke \
  --namespace hooke-system \
  --set global.clusterID=ack-smoke \
  --set image.repository=<ACR>/hooke \
  --set image.tag=<immutable-tag>
```

检查：

```bash
kubectl -n hooke-system get pods
kubectl -n hooke-system logs deploy/hooke-ingester
kubectl -n hooke-system logs deploy/hooke-controller
```

## 3. 创建实验运行

```bash
kubectl -n hooke-system port-forward svc/hooke-ingester 8080:8080

hookectl run create \
  --api http://127.0.0.1:8080 \
  --cluster ack-smoke \
  --name S01-fixed-node \
  --slo-seconds 30
```

记录返回的 `run_id`，然后激活：

```bash
kubectl -n hooke-system patch configmap hooke-active-run \
  --type merge -p '{"data":{"run_id":"<RUN_ID>"}}'
```

实验命名空间也标注：

```bash
kubectl create namespace hooke-experiments --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate namespace hooke-experiments hooke.io/run-id=<RUN_ID> --overwrite
```

## 4. S01：数据链路冒烟

部署单副本 smoke app。不要人为 sleep 或伪造 Node/ECS 事件。

```bash
sed \
  -e 's/REPLACE_RUN_ID/<RUN_ID>/g' \
  -e 's#REPLACE_SMOKE_IMAGE#<ACR>/hooke-smoke-app:<TAG>#g' \
  examples/smoke-app/k8s/deployment.yaml | kubectl apply -f -

kubectl -n hooke-experiments rollout status deploy/hooke-smoke-app
kubectl -n hooke-experiments run curl --rm -i --restart=Never \
  --image=curlimages/curl -- http://hooke-smoke-app/work
```

数据库检查：

```sql
SELECT event_type, COUNT(*)
FROM raw_events
WHERE run_id='<RUN_ID>'
GROUP BY event_type
ORDER BY event_type;
```

至少应看到：`POD_CREATED`、`POD_SCHEDULED`、`CONTAINER_STARTED`、`POD_READY`、应用 readiness 和首请求事件。

## 5. S02：固定节点 Image/Pod/App 冒烟

重复删除和重建 Deployment 3–5 次。分别记录镜像已有缓存和新 digest 两种情况，不手工清缓存。

```bash
kubectl -n hooke-experiments rollout restart deploy/hooke-smoke-app
```

Kubernetes Event 产生的 Image 事件应为 `approximate=true`。

## 6. S03：真实 ACK 节点扩容冒烟

给弹性节点池设置独有 label/taint，例如：

```text
hooke.io/pool=elastic
hooke.io/experiment=true:NoSchedule
```

测试工作负载配置匹配的 `nodeSelector` 和 `tolerations`，确保固定节点不能承载。弹性池保持 `min=0`，创建资源请求足够大的 Pod，真实触发 Pending → ACK 扩节点 → Node Ready。

执行期间采集 GOATScaler/SLS 日志并送入 `hooke-ack-adapter`。如果尚未接通 ACK 日志，轨迹只会得到 `POD_UNSCHEDULABLE → NODE_READY` 的扩展近似口径，不得标记为严格 L1。

至少重复 3 次真实扩容，确认没有任何测试脚本插入伪造 ACK 事件。

## 7. S04：关联与公式

```bash
hookectl calculate --dsn "$HOOKE_MYSQL_DSN" --run-id <RUN_ID>
hookectl report --dsn "$HOOKE_MYSQL_DSN" --run-id <RUN_ID>
```

检查：

```sql
SELECT * FROM pod_traces WHERE run_id='<RUN_ID>';
SELECT * FROM layer_samples WHERE run_id='<RUN_ID>';
SELECT * FROM metric_results WHERE run_id='<RUN_ID>';
SELECT * FROM v_trace_quality WHERE run_id='<RUN_ID>';
```

## Gate-S

全部满足后才能扩大节点数：

- 原始事件可幂等重放；
- Pod UID、Node Name、Container ID 可以关联；
- 至少 3 条完整 App 轨迹；
- 至少 3 次真实 ACK 节点扩容；
- 所有时延非负；
- 每个派生指标能追溯到起止事件；
- 近似事件占比可查询；
- 任何伪造或手工补写事件均不进入正式 run。
