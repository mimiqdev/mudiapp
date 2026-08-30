# Active plan — Herdr 工作流

**出口：** 用户可以从 App 首页找到 agent，并进入对应 terminal。

阶段 2 已提供可保存的 SSH Host。本步在已连接的 Host 上发现 Herdr 并 attach 到 pane。不要重做 SSH。

## 范围内

- **Herdr 契约以本机真实 CLI 为准。** 实现和测试解码必须对照 `herdr session list --json`、`herdr workspace list`、`herdr pane list`、`herdr agent list`、`herdr terminal session control` 的实际输出与 help。禁止自编 JSON / 字段名 / attach 协议。
- 连上 Host 后自动发现 session / workspace / tab / pane / agent 状态
- 0 个 session：空状态 + 普通 SSH terminal
- 1 个 session：直接展示 pane / agent
- 多个 session：先选 session
- 用户点 pane（或「恢复上次 pane」）才进入 terminal，不自动选 pane
- 点进去就进入可交互 terminal，不再问是否接管
- pane 没了就回到列表并说明

## 不在本步

- Host 保存 / Keychain / TOFU / 重连（阶段 2）
- shortcut bar、外接键盘、字体主题（阶段 4）
- Mosh（阶段 5）
- 首次权限说明（阶段 6）
- Chat UI、通知

## 测试

先把自动化测试落地成会失败，再做切片。真 Herdr / 真机 attach 不自动化。

### 自动化

导航逻辑可以用 fake。凡是解析 Herdr 输出或调用 CLI 的测试，必须用从真实 `herdr` 命令截下来的 payload，不许编一份“看起来像”的 JSON。

- 0 个 session：快照为空，可走普通 SSH terminal，不进入 pane attach
- 1 个 session：不出现 session picker，直接列出其 pane / agent
- 多个 session：先列出 session；选定之前不列出其他 session 的 pane
- 列出 pane 时不会自动 attach
- 用户选择某个 pane 后，才对该 pane 发起 attach
- 「恢复上次 pane」只在显式调用时 attach 那个 pane
- 目标 pane 已不存在时，回到列表并带上可展示的说明
- `make test-core` 通过

### 手工（出口，自动化全绿之后）

- 连上已保存 Host 后，能看到真实 Herdr 的 agent 列表
- 点一个 agent / pane，进入可交互 terminal
- 不会自动钻进某个 pane

## 切片

自动化测试已在仓库里且失败之后再写。

## 完成后

归档为 `archive/03-herdr-workflow.md`，将 `future/04-mobile-interaction.md` 提升为 `active_plan.md`。
