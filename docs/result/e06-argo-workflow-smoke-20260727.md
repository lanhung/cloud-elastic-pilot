# E06 ACK Argo Workflow 冒烟结果（2026-07-27）

## 结论

E06 的 1×2 ACK 配对冒烟通过。baseline 和 tuned 两个 Workflow 均成功，验证了
Argo 控制面、固定节点调度、不可变镜像、应用事件、业务依赖、关键路径计算和清理
链路。本次不是每版 30 次的正式统计实验。

```text
result: PASS (2/2 cells)
run_id: e06-20260727023438-43aa
baseline: A → B → C → D → E → F
tuned:    A → [B,C] → D → E → F
```

本地完整 artifact：

```text
artifacts/e06-argo-workflow-smoke-20260727023438-43aa
```

## 版本与环境

- ACK Managed Kubernetes：1.36.1
- Region：`cn-wulanchabu`
- Helm release：`argo/ack-workflow`
- Chart：`ack-workflow-3.5.15`
- workflow-controller：
  `registry-cn-wulanchabu-vpc.ack.aliyuncs.com/acs/workflow-controller:v3.5.13-f31bb8fe`
- E06 image source commit：`e45c95d089ffb6954238d8619aba6137c848cf9d`
- E06 image digest：
  `sha256:7cee4d7ad9bf6dcfbd13822aab434f674b5e007905982075cfe5c387eac57df9`
- 固定节点：`cn-wulanchabu.10.200.101.87`
- 随机区组：1
- cell：2
- Workflow SLO：30 秒

目标节点在执行前后保持同一 UID，始终为 Ready，且
Memory/Disk/PID/NTP condition 均无异常。该节点由 GOATScaler 管理，因此 runner
在每个 cell 前重新验证节点仍然存在且 Ready。

## 配对结果

| Cell | Workflow phase | Workflow 时长 | B/C 重叠 | 关键路径 | 关键路径时长 | 应用事件 |
| --- | --- | ---: | ---: | --- | ---: | ---: |
| baseline | Succeeded | 71 s | 0 s | A→B→C→D→E→F | 37 s | 12/12 |
| tuned | Succeeded | 60 s | 8 s | A→B→D→E→F | 28 s | 12/12 |

tuned 相比 baseline：

- Workflow 端到端时长减少 11 秒，即 15.49%；
- B/C 从不重叠变为真实重叠 8 秒；
- 关键路径从 6 个阶段缩短为 5 个阶段；
- 关键路径累计 Argo node 时长从 37 秒降为 28 秒。

两版保存的业务真实依赖完全相同：B、C 都只依赖 A，D 同时依赖 B、C。baseline
额外的 `B→C` 只是串行对照控制边，不被误记为业务依赖。

## Workflow 弹性计算

| Cell | predicted | measured | absolute error |
| --- | ---: | ---: | ---: |
| baseline | 0.29132 | 0.09379 | 0.19753 |
| tuned | 0.39324 | 0.13534 | 0.25791 |

单次配对中 measured elasticity 提高约 44.29%。这些数值只证明
runner 的 `Workflow CR → DAG → critical path → elasticity` 计算链能够使用真实
ACK 数据闭环，不代表稳定收益，也不用于评价模型精度。

## 原子事件与身份 Gate

共导出 24 条精确应用源时间事件。每个 cell 的 A–F 六个阶段都恰好具有：

- 1 条 `USEFUL_WORK_STARTED`；
- 1 条 `USEFUL_WORK_FINISHED`。

额外 Gate：

- 2/2 Workflow 的 phase 均为 `Succeeded`；
- 每个 Workflow 恰好有 6 个成功 Pod node，无 retry/duplicate；
- 12/12 Pod 成功，容器 restart count 总计为 0；
- 所有 Pod 的 owner UID 都精确匹配所属 Workflow UID；
- 所有 Pod 都运行在冻结的固定节点；
- 所有 main container 的 imageID 都匹配冻结的不可变 digest；
- baseline B/C overlap 为 0，tuned B/C overlap 为 8 秒；
- 业务真实依赖和控制依赖均与 manifest 注解一致。

## 冒烟中发现并修复的问题

首次只读预检暴露了 GOATScaler 节点标签 jq 表达式的多余转义。它会输出 jq 编译
错误，但因位于 shell 条件表达式中而错误地返回成功。提交 `da65ee0` 将标签读取
移到独立赋值并修正 jq key 语法；重新预检后正常识别
`goatscaler.io/managed=true`，再执行本次冒烟。

## 清理

运行结束后复查：

- 实验 Namespace `hooke-e06-20260727023438-43aa` 已删除；
- 集群级 `hooke-e06-argo-lock` Lease 已删除；
- 本地执行确认已恢复为 `CONFIRM_E06_EXECUTION=no`。

因此冒烟没有在 ACK 集群中留下 E06 实验资源。

## 口径限制

本次只有一个配对区组。Workflow 与 Argo node 的 `startedAt/finishedAt` 为秒级控制面
时间，阶段时长包含 Pod 生命周期和控制器开销；应用日志时间只用于证明有效工作
边界。本次由 runner 直接保存 CR、Pod 和日志证据，未覆盖 Hooke controller 在线
监听、MySQL 持久化和 correlator 消费的部署态链路。71 秒与 60 秒的差异不能外推为
稳定性能收益。若要形成正式结论，仍需按预定随机区组设计执行每版至少 30 次，并
报告分布、置信区间及顺序效应。
