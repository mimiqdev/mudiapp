# Active plan — Phase 16:快捷键扩展与 Agent 操作预设

**出口:** 手机端保留稳定的通用终端快捷栏,并能根据远端 Herdr 返回的当前 pane 的 agent 类型提供内置快捷操作;首批支持 Pi,无需额外安装 Mudi host hook。

## 范围内

- 通用快捷键扩展优先加入 Shift+Tab;保持现有 Esc、Tab、Ctrl、方向键、粘贴、Jump To 与键盘开关的位置和语义稳定,不把所有操作塞进底栏。保留 Tab 长按反向 Tab,面板提供显式 Shift+Tab;仅在滚动区末尾追加 Agent Actions 入口,Jump To 与键盘开关继续固定。
- 采用「通用快捷栏 + Agent Actions 弹出面板」。通用操作显示按键名称,agent 专属操作可显示语义名称及对应按键/命令。
- 手机通过现有 SSH discovery 消费 Herdr 的 pane/agent 信息(`Pane.agent.name/state`,已存在),不在手机解析 terminal 画面猜 agent 类型;pane 切换与类型刷新后更新预设,避免沿用旧 pane 的类型。
- 识别到 Pi 时推荐 Pi 预设，识别到 Claude Code 时推荐 Claude Code 预设;类型缺失或不支持时回退通用操作。面板明确显示当前预设,允许手动选择内置预设;这不等于自定义快捷键。
- Claude Code 首批候选操作来自官方文档（https://code.claude.com/docs/en/interactive-mode 与 /docs/en/commands）：/model、/context、/compact、/resume、/usage、/rewind、/clear、/tasks。/rewind 与 /clear 的确认必须说明回滚或清空影响。Ctrl+ 与 Shift+Tab 已由通用快捷栏原生提供，不重复列入。命令发送前确认；不猜测远端自定义 keybindings。
- Pi 预设仅含 /reload、/compact、/resume、/tree；Ctrl+、Shift+Tab 与 Esc 使用现有通用快捷栏。
- 发送策略(本次明确):按键类操作(Ctrl+L、Shift+Tab、Ctrl+O、Ctrl+T、Esc)与现有快捷栏一致,直接发送真实控制字节,不加确认;slash 文本类操作(/reload、/compact、/resume、/tree)发送**文本 + Enter**,但发送前显示确认弹层,弹层中完整展示将发送的命令文本——agent 类型不代表当前处于空白编辑器,确认防止误清上下文。
- 不新增 Herdr 协议或原生模型选择器,操作仍通过真实 terminal 输入链路(PTY 字节)完成。

## 不在本步

- 自定义快捷键(自定义文本、键序列、宏、固定/排序配置、配置同步)——高级功能,暂不规划。
- 其他 agent 预设(Claude Code、Codex 等)——另行确认,本步不承诺全量支持。
- Herdr 协议变更、通知推送(future/12)、桌面侧 hook。
- 终端外观、渲染引擎迁移(future/15)。

## 测试

**合同状态:用户已确认（继续）。** 先新增自动化测试并确认按预期失败,再实现。Pi 清单已核对本机 1.1.0 的 `docs/keybindings.md` 与 `docs/slash-commands.md`;面板说明使用默认绑定,远端自定义绑定须核对 `~/.pi/agent/keybindings.json`。真实 Herdr 0.9.3 CLI 的 `session list --json`、`workspace list`、`pane list`、`agent list` 已捕获到 `/tmp/mudi-phase16-*.json`,agent 类型字段为 `agent: "pi"`;没有新增协议。工作主机 SSH 当前不可达,远端版本和真机行为仍是手工验收项。

自动化记录（2026-10-13）：7 个新测试先在模拟器运行，因 Agent Actions 入口/面板不存在而失败；实现后 7/7 通过。iPhone 模拟器完整 XCTest 回归 380/380、HerdrKit 13/13 通过；iPad 新功能与 Capsule/Inset/iPad 快捷栏回归 22/22 通过。面板在两个模拟器上还验证了浮动区域真实触摸命中。日志分别为 `/tmp/mudi-phase16-red.log`、`/tmp/mudi-phase16-green.log`、`/tmp/mudi-phase16-regression.log`、`/tmp/mudi-phase16-core.log`、`/tmp/mudi-phase16-ipad.log`。**手工出口仍待真机验证，不归档、不自动发版。**

### 自动化(实现门)

- `testPiPaneAgentPresentsAgentActionsPanelWithBuiltInPresets`:pane.agent.name 识别为 Pi 时,面板出现并按内置 Pi 预设列出按键类与 slash 类操作,当前预设明确标注。
- `testClaudeCodePanePresentsVerifiedActionsAndCommands`:官方 agent 名 `Claude Code` 推荐第三套预设；Ctrl+C、Ctrl+O、Ctrl+T、Shift+Tab 直接发送真实控制字节，/model、/context、/compact、/resume 先确认再发送文本加 Enter。
- `testMissingOrUnsupportedAgentTypeFallsBackToGenericOperations`:pane.agent 缺失或名称不识别时,面板仅含通用操作(与现有快捷栏语义一致),不显示 agent 专属项。
- `testManualPresetSelectionPersistsWithinPaneContext`:面板允许手动选择内置预设;同一 pane 上下文内保持所选预设,pane 切换后按新 pane 的类型重新推荐。
- `testAgentKeyActionsSendRealControlBytes`:Pi 按键类操作经 PTY 发送真实字节(Ctrl+L=0x0C、Shift+Tab 序列、Ctrl+O=0x0F、Ctrl+T=0x14、Esc=0x1B),不注入文本模拟。
- `testSlashCommandRequiresConfirmationThenSendsTextAndEnter`:slash 操作先出确认弹层(展示完整命令文本);确认后发送「文本 + Enter(0x0D)」;取消则不发送任何字节。
- `testPaneSwitchOrTypeRefreshUpdatesPresetWithoutStaleType`:pane/Host/Herdr session 切换或 agent 类型刷新后,面板按新上下文推荐,不沿用旧预设;待确认命令同步作废,输入被暂停或 terminal 被卸载后也不能发送到旧/新会话。
- `testGenericShortcutBarLayoutAndSemanticsUnchanged`:现有 Esc、Tab、Ctrl、方向键、粘贴、Jump To、键盘开关的位置与语义回归不变;Shift+Tab 扩展不挤占既有键位。
- 回归基线:Phase7 快捷栏测试(CapsuleBar/Inset)与 Phase4 交互测试全绿。

### 手工(出口)

- 真机连接运行 Pi 的 Herdr pane:逐项验证 Pi 预设操作在远端 Pi 当前版本上的真实行为(模型选择、thinking 循环、折叠开关、slash 命令),按结果定稿最终操作清单。
- 非 Pi pane 与无 agent 信息 pane:面板回退通用操作,无误导项。
- slash 命令确认弹层:确认前终端无任何输入;确认后命令与 Enter 到达,且不额外清空远端输入。
- 现有快捷栏手感回归:Esc/Tab/Ctrl latch/方向键/粘贴/Jump To 行为与 Phase 7 一致。

## 切片

以下切片已按先红后绿实施；当前仅完成自动化验证。

1. Agent 类型识别与预设映射(pane.agent.name → 内置 Pi 预设;缺失/未知 → 通用)
2. Agent Actions 弹出面板(当前预设显示、手动选择、回退)
3. 发送链路:按键类真实字节;slash 类确认后文本+Enter
4. Shift+Tab 加入通用快捷栏;预设随 pane 切换/类型刷新更新
5. 回归验证(Phase7/Phase4 套件)

## 完成后

- 归档名:`docs/plan/archive/16-agent-shortcut-presets.md`
- 下一个:`docs/plan/future/12-agent-event-notifications.md`(或按用户调整)

## 真机反馈修正（2026-10-14）

- Pi 预设仅保留 /reload、/compact、/resume、/tree；Ctrl+ 与 Shift+Tab 使用现有通用快捷栏。
- 按键发送或命令确认发送后收起面板；取消确认保留面板，不发送字节。
- 用户确认手动模型列表 workaround：快捷面板仅保留模型选择入口；独立列表页滚动选择，配置在独立编辑页，Pi/Claude Code 分开保存。支持模型 ID 或完整 /model 命令输入；选择后确认粘贴，再间隔 150ms 单独发送 Enter，校验 host/session/context 未变化。自动发现暂不实施。
- 最终模拟器 429/429、Mimikyu 真机专项 9/9 通过。用户真机反馈“看起来ok了”，授权提交、推送、创建 PR。记录 PTY 测试不替代真实远端验证。

## 系统键盘 + 导航 accessory（2026-10-14，用户确认方向）

- 用户决定：Ctrl/Alt 锁定期复用系统英文键盘（隐藏 ASCII responder），仅自绘 44pt 导航条（Ctrl/Alt 状态 + Home/End/PgUp/PgDn/←/→/Tab/Del，横向滚动边缘渐隐）挂在其键盘上方；发送/取消后恢复原中文输入法与终端焦点。原则：除非万不得已不自绘键盘字母区。
- 逻辑资产沿用 Phase 16 修饰键盘合同：单次语义、全部清锁路径（IME 组合/切会话/切 Host/暂停输入/后台/离窗/硬件键盘接入）、序列编码与会话 generation 防护。
- 验证：模拟器 iPhone 437/437、iPad 37/37；真实键盘 UI 与 zh-Hans → en-US → zh-Hans 恢复在独立 spike 中验证。真机切换手感待 TestFlight 真机体验。

## 玻璃快捷栏与本地化反馈（2026-10-14）

- 用户真机确认系统英文键盘切换没有问题；保留 accessory 方案，不恢复自绘字母键盘。
- 快捷栏与 Agent 面板使用 iOS 26+ UIGlassEffect，较旧系统回退超薄材质。Agent 面板占用原键盘槽位，键盘收起不改变终端 frame；Pi 以模型/Thinking/三列命令卡片呈现，新增 /new /export 已核 Pi 文档。Thinking 精确设置走 /thinking level 并沿用文本命令确认规则，不推断远端状态。
- 补齐 140 条 en/zh-Hans 文案，覆盖 Thumb Arc 设置/练习、Agent、快捷模型、Ctrl/Alt accessory、Compose 和实验引擎提示。用户文本、模型名与协议命令不翻译。
- 最终模拟器英文全量 441/441、中文专项 23/23、iPad 专项 40/40；玻璃界面深浅色及中英截图均已生成。用户已授权本轮创建 PR 和 TestFlight 发布。
