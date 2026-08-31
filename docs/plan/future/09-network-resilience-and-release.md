# 9. 网络韧性与发布验收

**出口：** 在可用的蜂窝网络和外测条件下完成 V1 最终验收并具备 TestFlight 发布条件。

- 真机验证 Wi-Fi / 蜂窝切换、短暂断网和前后台后的 Mosh session 恢复
- 验证回到原 Herdr pane；明确 SSH control 与 Mosh transport 的实际边界
- 无 `mosh-server` Host 的 Auto → SSH 真机回退
- 日志脱敏、崩溃恢复、性能和完整 V1 真机回归
- 根据网络结果确认继续 swift-mosh；仅在阻塞时重新评估 libmoshios 和 GPL 履约
- TestFlight 签名、隐私说明、第三方许可和外测材料
