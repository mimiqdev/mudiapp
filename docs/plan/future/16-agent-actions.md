# 16. Agent Actions 快捷操作

**出口：** 保留通用 terminal 快捷栏，并可在 Herdr pane 上提供按 agent 类型推荐的内置操作；类型缺失/不支持时回退通用操作。

- 通用快捷键与 Pi 等 Agent Actions 分层，不重排现有快捷栏语义。
- 按键类经现有 PTY 发真实控制字节；slash 文本类先展示完整确认内容，再发送文本与 Enter。
- 按 pane 类型刷新预设，不从屏幕猜 agent；不增加 Herdr 协议、自定义宏或未经确认的其他 agent。
- 当前 Phase 15 完成并经用户确认前暂停；不代表验收主 checkout 未提交的 Phase 16 实现。
