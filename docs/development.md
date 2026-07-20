# 开发规范

## 技术栈

- Go：控制器、agent、ingester、关联器、CLI 和 SDK；
- client-go：只读 Informer 与动态 CRD 监听；
- MySQL 8.0+：不可变原始事件与可复算派生结果；
- Prometheus：服务健康和采集器聚合指标；
- Helm：ACK 部署；
- cilium/ebpf 或 libbpf：精确探针阶段，当前仅保留接口。

## 代码规则

- `internal` 中禁止循环依赖；
- collector 不依赖 MySQL；
- 原子事件类型集中定义；
- 时间统一 UTC/Epoch ns；
- 新事件必须补充契约文档和测试；
- 派生公式必须有边界测试；
- 不在 watcher 回调中执行网络阻塞；
- 任何可能丢事件的队列必须暴露计数；
- 禁止在仓库中提交 ACK AccessKey、RDS 密码或 Token。

## 本地验证

```bash
make tidy
./scripts/verify.sh
```

## 新增 Collector

1. 先定义原子事件；
2. 明确事实时间来源；
3. 明确 `approximate`；
4. 使用 UID 关联；
5. 在状态缓存中定义去重 fingerprint；
6. 加单元测试和真实样本 fixture；
7. 更新 Helm RBAC。

## 版本升级

Kubernetes/client-go、containerd 和 kubelet 升级必须单独 PR。eBPF 探针必须按 build-id 回归，不能只靠语义版本。
