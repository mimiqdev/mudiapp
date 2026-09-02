# Active plan — 网络韧性

**出口：** Wi-Fi、蜂窝（5G）、Tailscale-over-cellular 等真实网络组合下，Mudi 连接稳定、切换无感；已知连接失败场景全部消除或有明确解释。

阶段 8 已完成 terminal 外观。本步只做网络连接的可靠性，发布准备不在本阶段。

## 范围内

- **首先复现并修复**：5G 蜂窝 + Tailscale（tailnet 内设备）连接超时失败——其他终端 App 在同样条件下可连，这是 Mudi 的 bug，不是环境限制
  - 排查方向：IPv6/IPv4 解析与 Happy Eyeballs（NIO connect 路径）、Tailscale MagicDNS 解析、连接超时与重试、Mosh UDP 在 tailnet 上的路径、tailnet 隧道未就绪时的行为
- 多网络组合真机验收：Wi-Fi、蜂窝、Wi-Fi↔蜂窝切换、Wi-Fi/蜂窝 ↔ Tailscale 的交叉组合
- 网络切换/短暂断网后的 Mosh session 恢复与 transparent reconnect 行为
- 无 `mosh-server` Host 的 Auto → SSH 回退在真实网络下的验证
- SSH control 与 Mosh transport 的边界在网络异常下的行为一致性
- 连接失败文案：超时/不可达/拒绝的本地化与可区分性

## 不在本步

- TestFlight、签名、隐私说明、发布材料（独立阶段）
- Herdr 协议变更
- 通知推送（future/11）
- 触屏光标重做（future/12）

## 测试

先写自动化测试并确认失败，再实现。真实网络组合以真机手工验收为准。

### 自动化

- 连接路径的地址族处理：IPv6-only / IPv4-only / 双栈地址列表的连接策略（Happy Eyeballs 或等效竞速/回退）有模型测试
- 连接超时可配置且有合理默认值；蜂窝级别的慢连接不会过早超时
- Auto 模式 Mosh 失败回退 SSH 的判定覆盖"UDP 被 tailnet/运营商阻断"的情形
- 网络中断恢复：transport 层断开与重连的状态机测试（复用阶段 7 transparent reconnect 接缝）
- `make test-core` 和 Mudi XCTest 通过（模拟器）

### 手工（出口）

- 5G + Tailscale 连接成功且稳定
- Wi-Fi ↔ 蜂窝切换后 session 恢复（透明重连不打扰）
- 断网 → 恢复 → 回到原 pane，无错误残留
- 无 mosh-server 的 Host 走 SSH 正常

## 切片

- 诊断并修复 tailnet 连接失败（地址解析/竞速/超时）。
- 连接策略（地址族竞速、超时、回退）做成可测 policy。
- 多网络组合真机矩阵验收。

## 完成后

归档为 `archive/09-network-resilience.md`，将 `future/10-release.md` 提升为 `active_plan.md`。
