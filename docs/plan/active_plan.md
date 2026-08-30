# Active plan — 移动端完整交互

**出口：** 纯触屏可以完成日常主流程：进 Host、看 Herdr、进 pane、回看、复制、再回到 Host 列表。

阶段 3 已能发现 Herdr 并 attach。本步补触屏交互和导航，不要重做 SSH 或 attach 协议。

## 范围内

- Herdr 列表能回到 Host 列表（断开当前连接）
- 进 pane 后标题用 pane / agent 名，不用 Host IP
- 触屏能滑回 scrollback，看已经输出的内容
- shortcut bar、modifier、选择、复制、粘贴
- 记住并恢复 Host、上次 pane、界面位置
- 外接键盘、鼠标、触控板的基础行为
- 可切换主题：System / Light / Dark，默认跟随系统，并记住选择
- 可调 terminal 字号；自带一款 Nerd Font 等宽（不做字体文件导入、不做成套 palette）
- Dynamic Type、基础无障碍
- 涉及 Herdr 的帧仍以真实 CLI 为准。回看若走 `herdr terminal session control` 的 `terminal.scroll`，必须对照本机真实命令，禁止自编 JSON

## 不在本步

- Herdr discovery / attach 协议（阶段 3）
- Mosh（阶段 5）
- 首次本地网络权限（阶段 6）
- Chat UI、通知
- terminal 里快捷切 pane（仍待定，本步不做）

## 测试

先把自动化测试落地成会失败，再做切片。真机触屏、外接键盘、复制粘贴不自动化。

### 自动化

- 从 Herdr 列表返回后回到 Host 列表；当前连接已断开，不再展示 pane 列表
- attached terminal 的标题来自 pane 或 agent，不是 Host.hostname
- 冷启动后 Host 仍在；「恢复上次 pane」仍只在显式调用时 attach
- 主题选择为 System / Light / Dark，默认 System；保存后再读仍是上次的选择
- terminal 字号可读写，保存后再读仍是上次的字号
- 若本步发送或解码 `terminal.scroll` / `terminal.frame`，测试必须用录下的真实 CLI 帧，不许编
- `make test-core` 通过

### 手工（出口，自动化全绿之后）

- 真机从 Herdr 列表能回到 Host 列表，再连同一台或另一台
- 进 pane 后标题是 pane / agent，不是 IP
- 手指能滑回去看 agent 已经发出的内容
- 能选择、复制、粘贴
- shortcut bar 能发出常用键
- 外接键盘能输入
- 能改主题和字号，terminal 仍可读

## 切片

自动化测试已在仓库里且失败之后再写。

## 完成后

归档为 `archive/04-mobile-interaction.md`，将 `future/05-mosh-and-release.md` 提升为 `active_plan.md`。
