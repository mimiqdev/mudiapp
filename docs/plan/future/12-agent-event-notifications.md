# 10. Agent 事件推送与通知（调研候选）

**出口：** agent 需要用户介入（blocked/审批）或回合完成时，Mudi 能在后台收到通知并一键回到对应 pane；机制选型（是否需要桌面侧 hook、直连轮询或服务端推送）经真机调研确认。

- 调研推送机制选型：
  - 桌面侧 hook/守护进程（参考 moshi-hook 读 `$HERDR_ENV` 的做法）：是否必要、安装负担、与 Herdr socket API 的边界
  - 纯客户端方案：iOS 后台推送 (APNs) / 本地通知 / 前台轮询 discovery 的取舍
  - Herdr socket API（本地）能否远程化或经 SSH 隧道订阅事件流
- 通知 → pane 深链：点通知回到 Host、重连并 retakeover 对应 workspace/pane
- 与阶段 9 的网络韧性配合：断线期间事件不丢（服务端缓存/重放）
- 明确不是 V1 范围；v1 依赖现有 NDJSON 控制协议
