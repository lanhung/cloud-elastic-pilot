# 安全基线

- 使用只读 ClusterRole；
- MySQL DSN 和 ingest token 来自 Secret；
- 默认非 root、RuntimeDefault seccomp、drop all capabilities；
- CPU 冒烟阶段 node-agent 不启用 privileged/hostPID；
- eBPF 阶段单独创建最小权限 DaemonSet，不修改默认部署；
- ACK/SLS/ECS 访问优先使用 RRSA 临时凭证；
- `hooke-ack-adapter` 的外部入口应限制来源并启用 Token/mTLS 网关；
- 数据库账户仅授予 Hooke schema 的 DML/DDL（迁移账户和运行账户最好分离）。
