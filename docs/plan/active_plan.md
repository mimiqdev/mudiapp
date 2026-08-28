# Active plan — SSH 可交互 terminal

**出口：** 在模拟器或真机上，通过 SSH 打开一个可交互 terminal。

## 范围内

- 继续使用现有 iPhone / iPad 骨架、`HerdrKit` 领域模型和依赖边界
- 能指定一台 Host（UI 可以很粗）并完成 SSH 认证
- Citadel：登录、PTY、双向数据、窗口尺寸同步
- SwiftTerm 接到字节流、键盘输入写回、resize

## 不在本步

- Host 配置产品化、Keychain、host key UX、连接状态和手动重连（阶段 2）
- Herdr discovery / `terminal session control` attach（阶段 3）
- shortcut bar、外接键盘打磨、字体和主题（阶段 4）
- Mosh、Auto transport、libmoshios（阶段 5）
- GhosttyKit 对照（可另开 spike，不挡出口）

## 切片

1. 最小 Host 输入（或临时调试配置），足以发起一次 SSH 连接
2. Citadel SSH + PTY 接到 SwiftTerm，打通交互 shell
3. 窗口或键盘导致的 resize 同步到远端

## 验证

- 模拟器或真机连接到一台真实 SSH host
- 能输入命令并看到输出
- 改变 terminal 尺寸后，远端 rows/cols 会更新
- `make test-core` 仍然通过

## 完成后

归档为 `archive/01-ssh-interactive-terminal.md`，将 `future/02-ssh-vertical-slice.md` 提升为 `active_plan.md`，并补全切片和验证。
