# Active plan — Phase 15: libghostty iOS 调研与门控 A/B

**状态：** 阶段 A 调研与独立 harness 已完成；阶段 B 等待用户确认候选路线/测试合同。此工作树基于 `0e5250d37e21f2f7345940a52f4044ed789fc90d`，不含主 checkout 未提交的 Phase 16 Agent Actions 改动。Phase 16 未验收、暂停且未归档；本计划不实施它。

**出口：** 用户确认路线后，以 SwiftTerm 为默认完成一条 opt-in renderer A/B 路径；实验不可用时明确回退，已确认的自动化与真机合同全绿。只证明受控试验，不代表全量迁移或可移除 SwiftTerm。

## 范围内

- 依据 `docs/research/libghostty-ios.md` 固定候选版本/来源、验证 arm64 iOS device 与 simulator 接入，并保留可复现 harness。
- 推荐候选：`Lakr233/libghostty-spm@d403978c66870baa422709d1dde385730a4bdaef` 的 `GhosttyTerminal`，作为 SwiftTerm 默认之上的 opt-in full surface。
- 用户确认后的最小接入仅替换 terminal adapter/view；SSH、Mosh、Herdr 继续使用现有 PTY/session 接口。Ghostty package 自带 input accessory 要关闭（UIKit `TerminalViewState.inputAccessoryItems=[]`），沿用 Mudi 自己的快捷栏。

## 不在本步

- 默认 renderer 切换、SwiftTerm 移除、声称完成全量 Ghostty 迁移。
- 改 Herdr/Mosh/SSH wire、TOFU、idle policy、重连策略或 transport 语义。
- 未确认前新增 App 设置开关、产品代码或产品测试。
- Phase 16 Agent Actions、其他 `future/` 项、真机安装/设备测试（须另获确认）。

## 测试

**合同状态：待用户确认。** 以下是本轮推荐合同；确认前不写这些产品测试、不开始切片。若候选公开 API 无法提供真实可观测证据，先缩小范围并再次确认，不能用 mock renderer 宣称通过。

### 自动化（实现门；确认后先写并观察预期失败）

- `testFreshInstallKeepsSwiftTermAsDefault`: 新安装及无旧偏好时仍挂载 SwiftTerm；不选择实验引擎也不改变现有 session。
- `testExperimentalSurfaceOrExplicitFallbackUsesSameSession`: opt-in 后确实创建候选 surface；创建失败时显示明确状态并用同一 `SSHShellSession` 回退 SwiftTerm，不重复连接。实现前确认候选的启动失败能被公开 API 可靠观测；不能观测则停止并重议合同。
- `testRealVTFeedRetainsTextAndGridState`: 实际候选接收分片 PTY 输出并可读回 viewport 文本/网格；使用真实引擎而非 parser/mock view。宽字符、ANSI256、24-bit RGB 以真实渲染可观察证据覆盖；若无稳定的自动读回接口，改为真机验收项，不伪造接口。
- `testKeyboardAndCommittedIMETextReachExistingPTY`: 候选键盘与组合文本提交经现有 PTY `send` 路径；记录并断言真实字节/文本，不创建第二条网络连接。
- `testVisibleGridResizeReachesSamePTY`: resize 按 terminal view 实际可见网格（含快捷栏、安全区/键盘布局）计算，并发到原 session。
- `testGhosttyAccessoryDoesNotDuplicateMudiShortcutBar`: 隐藏候选默认 accessory 后，Mudi 持续快捷栏位置/语义不变。
- `testThemeFontSelectionClipboardAndScrollbackRemainObservable`: Mudi theme/font 映射、选中复制/粘贴、scrollback 与原语义一致；Herdr remote scroll 与 Mosh mouse-wheel 仍各走原通道。
- `testSessionReplacementBackgroundAndHostSwitchPreserveContext`: session 替换、后台返回、多 Host 切换不丢活动内容/焦点、不静默重复连接，并验证候选输出 backlog/backpressure（含其 1 MiB pre-attach 队列边界）；不支持跨引擎保留 parser/screen state 时，选择变更只在下一次挂载生效并明确告知，不静默清 scrollback。
- 回归：保留 Phase 4 交互、Phase 7 快捷栏、Phase 8 terminal layout/theme、Herdr frame 与 Mosh data-plane 回归。

### 手工（出口）

- 用户确认并授权后，在 iOS 17+ 真机检查 Metal 首帧/持续刷新、resize/大 TUI、Unicode 宽字、ANSI256/真彩、Mudi 主题/字体及 selection/copy/paste/scrollback。
- 中文/日文/韩文 IME marked text 与提交、软件/硬件键盘、Ctrl/D-pad/Composer/ThumbArc 的字节路径、键盘连续性。
- 现有 SSH、Mosh、Herdr Host 上验证后台返回、多 Host 切换与 session 替换：上下文保留且不重复连接；不得改协议或安全策略。

## 切片

(用户确认合同后先添加自动化测试并观察预期失败，再填写产品切片。本轮仅完成调研与 standalone harness。)

## 完成后

- 归档名：`docs/plan/archive/15-libghostty-ios-spike.md`（仅用户确认且出口验收后）。
- 下一个：`docs/plan/future/16-agent-actions.md`；Phase 16 在主 checkout 合流并确认前保持暂停。
