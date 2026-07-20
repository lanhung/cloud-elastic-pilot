# Go 应用埋点 SDK

SDK 只负责发送原子事件，不计算派生指标。

```go
client, _ := hooke.New(hooke.ConfigFromEnv())

mux.Handle("/readyz", client.ReadinessHandler(http.HandlerFunc(ready)))
handler := client.FirstRequestMiddleware(mux)

_ = client.Emit(ctx, event.GangBarrierEnter, map[string]any{"rank": 0})
_ = client.Emit(ctx, event.GangBarrierExit,  map[string]any{"rank": 0})
```

Pod UID、命名空间和节点名建议通过 Downward API 注入环境变量。
