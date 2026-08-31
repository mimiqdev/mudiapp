# Active plan — Mosh、韧性与发布准备

**出口：** 切网、短暂断网后还能回到原来的 Herdr pane；Auto / Mosh / SSH 可选；具备进入外部测试的材料。

阶段 4 已能纯触屏走完 Herdr attach。本步补移动网络韧性，不要重做 SSH attach 协议或触屏栏。

## 范围内

- Host 的 transport：Auto / Mosh / SSH，并记住选择
- Auto：先 SSH bootstrap，能上 Mosh 就用 Mosh，否则留在 SSH，并显示实际 transport
- Mosh 复用已保存的 SSH Keychain 凭据，不另存一套
- 验证 Wi-Fi / 蜂窝切换、短暂断网、前后台后 session 还在
- 根据真机结果决定继续 swift-mosh，或换 libmoshios 并做 GPL 履约
- 日志脱敏、崩溃后能再打开、真机过一遍 V1 主流程
- TestFlight 所需的签名、隐私说明、许可文本（需付费 Apple Developer）

## 不在本步

- Herdr discovery / attach JSON（阶段 3）
- shortcut bar、回看、主题字号（阶段 4）
- 统一 Herdr Pane Picker（阶段 6）
- 首次本地网络权限说明（阶段 7）
- 自定义字体 / Nerd Font（阶段 8）
- Chat UI、推送、Live Activity
- 自编 Mosh 或 Herdr 协议

## 测试

先把自动化测试落地成会失败，再做切片。真机切网不自动化。

### 自动化

- Host 能保存并读回 Auto / Mosh / SSH
- Auto 在 Mosh 不可用时回退 SSH，且能读到实际 transport
- Mosh 建连使用已有 SSH 凭据，不把密钥写进 Host 文件
- `make test-core` 通过

### 手工（出口，自动化全绿之后）

- 真机 Wi-Fi ↔ 蜂窝或短暂断网后，还能回到刚才的 pane，不必重找 agent
- 后台再回来，控制权按阶段 4 的 release / takeover 仍合理
- 无 mosh-server 的 Host 能用 SSH 完成同一条主流程
- 需要外测时，TestFlight 材料齐（否则先不挡 SSH/Mosh 主路径）

## 切片

自动化测试已在仓库里且失败之后再写。本次切片已将 transport 选择移入生产 coordinator：SSH bootstrap 后尝试 swift-mosh，Auto 失败留在 SSH，并在终端显示实际 transport。

## 完成后

归档为 `archive/05-mosh-and-release.md`，将 `future/06-herdr-pane-picker.md` 提升为 `active_plan.md`。
