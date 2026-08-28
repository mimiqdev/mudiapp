# 5. Mosh、韧性与发布准备

**出口：** V1 成功标准通过真机验收，可以进入外部测试。

- 完成 Mosh transport，并实现 Auto / Mosh / SSH transport 选择
- 验证网络切换、短暂断网、前后台切换和 session 恢复
- 根据技术验证结果确定继续使用 swift-mosh，或切换到 libmoshios 并完成 GPL 履约
- 补齐安全审查、日志脱敏、性能、崩溃恢复和真机测试
- 准备 TestFlight 所需的签名、隐私说明、许可文本和发布材料
