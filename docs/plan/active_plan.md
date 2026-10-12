# Active plan — Phase 16:快捷键扩展与 Agent 操作预设

**出口:** 手机端保留稳定的通用终端快捷栏,并能根据远端 Herdr 返回的当前 pane 的 agent 类型提供内置快捷操作;首批支持 Pi,无需额外安装 Mudi host hook。

## 范围内

- 通用快捷键扩展优先加入 Shift+Tab;保持现有 Esc、Tab、Ctrl、方向键、粘贴、Jump To 与键盘开关的位置和语义稳定,不把所有操作塞进底栏。
- 采用「通用快捷栏 + Agent Actions 弹出面板」。通用操作显示按键名称,agent 专属操作可显示语义名称及对应按键/命令。
- 手机通过现有 SSH discovery 消费 Herdr 的 pane/agent 信息(`Pane.agent.name/state`,已存在),不在手机解析 terminal 画面猜 agent 类型;pane 切换与类型刷新后更新预设,避免沿用旧 pane 的类型。
- 识别到 Pi 时推荐 Pi 预设;类型缺失或不支持时回退通用操作。面板明确显示当前预设,允许手动选择内置预设;这不等于自定义快捷键。
- Pi 首批候选操作:模型选择(Ctrl+L)、循环 thinking level(Shift+Tab)、工具输出折叠(Ctrl+O)、thinking 内容折叠(Ctrl+T)、中止(Esc)、/reload、/compact、/resume、/tree。实施前按远端 Pi 版本确认行为与最终清单。
- 发送策略(本次明确):按键类操作(Ctrl+L、Shift+Tab、Ctrl+O、Ctrl+T、Esc)与现有快捷栏一致,直接发送真实控制字节,不加确认;slash 文本类操作(/reload、/compact、/resume、/tree)发送**文本 + Enter**,但发送前显示确认弹层,弹层中完整展示将发送的命令文本——agent 类型不代表当前处于空白编辑器,确认防止误清上下文。
- 不新增 Herdr 协议或原生模型选择器,操作仍通过真实 terminal 输入链路(PTY 字节)完成。

## 不在本步

- 自定义快捷键(自定义文本、键序列、宏、固定/排序配置、配置同步)——高级功能,暂不规划。
- 其他 agent 预设(Claude Code、Codex 等)——另行确认,本步不承诺全量支持。
- Herdr 协议变更、通知推送(future/12)、桌面侧 hook。
- 终端外观、渲染引擎迁移(future/15)。

## 测试

**合同状态:待用户确认。** 先新增自动化测试并确认按预期失败,再实现。

### 自动化(实现门)

- `testPiPaneAgentPresentsAgentActionsPanelWithBuiltInPresets`:pane.agent.name 识别为 Pi 时,面板出现并按内置 Pi 预设列出按键类与 slash 类操作,当前预设明确标注。
- `testMissingOrUnsupportedAgentTypeFallsBackToGenericOperations`:pane.agent 缺失或名称不识别时,面板仅含通用操作(与现有快捷栏语义一致),不显示 agent 专属项。
- `testManualPresetSelectionPersistsWithinPaneContext`:面板允许手动选择内置预设;同一 pane 上下文内保持所选预设,pane 切换后按新 pane 的类型重新推荐。
- `testAgentKeyActionsSendRealControlBytes`:Pi 按键类操作经 PTY 发送真实字节(Ctrl+L=0x0C、Shift+Tab 序列、Ctrl+O=0x0F、Ctrl+T=0x14、Esc=0x1B),不注入文本模拟。
- `testSlashCommandRequiresConfirmationThenSendsTextAndEnter`:slash 操作先出确认弹层(展示完整命令文本);确认后发送「文本 + Enter(0x0D)」;取消则不发送任何字节。
- `testPaneSwitchOrTypeRefreshUpdatesPresetWithoutStaleType`:pane 切换或 agent 类型刷新后,面板按新 pane 类型更新,不沿用旧 pane 的预设(无 stale 类型)。
- `testGenericShortcutBarLayoutAndSemanticsUnchanged`:现有 Esc、Tab、Ctrl、方向键、粘贴、Jump To、键盘开关的位置与语义回归不变;Shift+Tab 扩展不挤占既有键位。
- 回归基线:Phase7 快捷栏测试(CapsuleBar/Inset)与 Phase4 交互测试全绿。

### 手工(出口)

- 真机连接运行 Pi 的 Herdr pane:逐项验证 Pi 预设操作在远端 Pi 当前版本上的真实行为(模型选择、thinking 循环、折叠开关、slash 命令),按结果定稿最终操作清单。
- 非 Pi pane 与无 agent 信息 pane:面板回退通用操作,无误导项。
- slash 命令确认弹层:确认前终端无任何输入;确认后命令与 Enter 到达,且不额外清空远端输入。
- 现有快捷栏手感回归:Esc/Tab/Ctrl latch/方向键/粘贴/Jump To 行为与 Phase 7 一致。

## 切片

(测试失败并经确认后填写)

1. Agent 类型识别与预设映射(pane.agent.name → 内置 Pi 预设;缺失/未知 → 通用)
2. Agent Actions 弹出面板(当前预设显示、手动选择、回退)
3. 发送链路:按键类真实字节;slash 类确认后文本+Enter
4. Shift+Tab 加入通用快捷栏;预设随 pane 切换/类型刷新更新
5. 回归验证(Phase7/Phase4 套件)

## 完成后

- 归档名:`docs/plan/archive/16-agent-shortcut-presets.md`
- 下一个:`docs/plan/future/12-agent-event-notifications.md`(或按用户调整)
