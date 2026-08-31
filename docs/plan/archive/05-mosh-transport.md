# 5. Mosh transport

**出口：** Host 可选 Auto / Mosh / SSH；Auto 能通过 SSH bootstrap 使用 Mosh 或回退 SSH，并显示实际 transport。

## 已完成

- Host 保存并恢复 Auto / Mosh / SSH
- Auto 先建立 SSH bootstrap，再尝试 swift-mosh；失败保留 SSH
- 显式 Mosh 不可用时给出明确错误，不静默回退
- Mosh 复用 Keychain SSH 凭据，不把密码或密钥写入 Host
- terminal 显示实际 transport；主动离开时不闪断连错误
- iOS 中文输入法的 marked text 显示在 shortcut bar；只发送提交后的文字
- 真机连接到真实 `mosh-server`，确认实际 transport 为 Mosh
- 继续使用 swift-mosh；若后续网络验收发现阻塞再重新评估

## 验证

- `make test-core` 通过
- Mimikyu 真机 XCTest：45/45 通过，其中 Phase 5 Mosh 5/5
- 独立 review：无 actionable findings
- 真机中文输入组合文字、提交与 shortcut bar 恢复通过

## 延后

以下需要更合适的蜂窝网络和发布条件，移至阶段 9：

- Wi-Fi / 蜂窝切换、短暂断网与 Herdr pane 恢复
- 无 `mosh-server` Host 的真机 Auto 回退
- 日志脱敏、崩溃恢复、完整 V1 真机回归
- TestFlight 签名、隐私、许可和外测材料
