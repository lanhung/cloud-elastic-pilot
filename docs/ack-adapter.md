# ACK 日志适配器

## 设计目的

ACK 托管控制面的日志字段会受组件版本、日志项目和采集方式影响，因此适配器采用配置化字段路径，而不是把某一版日志格式写死进代码。

## 输入方式

### HTTP

```bash
curl -X POST http://hooke-ack-adapter:8082/v1/ack-records \
  -H 'Content-Type: application/json' \
  --data-binary @record.json
```

支持一个 JSON 对象或对象数组。

### NDJSON/stdin

```bash
cat exported-sls.ndjson | hooke-ack-adapter \
  --config /etc/hooke/ack-adapter.yaml \
  --stdin
```

适合先导出 SLS 查询结果验证映射，再决定是否增加直接 SLS Consumer。

## 配置流程

1. 从真实 GOATScaler/SLS 记录中抽取 20–50 条样本；
2. 确认事件时间、任务 ID、实例 ID、节点名和 Pending Pod 字段；
3. 编写规则；
4. 用 stdin 模式回放；
5. 在 `raw_events` 中核对；
6. 只有核对通过后才接入持续日志流。

## 当前边界

仓库未内置阿里云访问密钥，也未假定 SLS project/logstore。直接 SLS Consumer 应在获得实际地域、project、logstore、topic 和 RRSA 权限后实现，复用 `ack.Parser` 即可。当前 HTTP/stdin 适配器已经能处理真实导出记录，不会生成模拟记录。
