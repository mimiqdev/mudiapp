# Active plan — UX Polish 第二轮

**出口：** 日常使用中积累的 UX 摩擦点被集中打磨；Host 支持多地址；可同时保持多条 Host 连接，返回列表不等于断开；连接过程可见、可取消。

阶段 9 已完成网络韧性验收。本阶段打磨日常使用体验，不做新协议能力。

## 范围内

- **连接反馈（第一刀）**：Host 列表点击连接后立即可见 connecting 状态动画；连接超过约 5 秒仍无结果时，行右侧出现取消按钮；点取消中止本次连接尝试并回到点击前状态，不产生半开连接
- Host 多地址：同一 Host 可添加多个地址（如 LAN IP、Tailscale IP、公网域名），编辑表单支持增删与拖动排序
- 连接按用户自定义顺序尝试（串行 + 每地址短超时）；TOFU 与凭据按 Host 共享（同一台机器不因换地址重复确认）
- 智能提升（上次成功地址自动提前）做成可选开关，默认尊重手动顺序
- 连接过程/结果可见当前实际使用的地址
- 原生 compose 输入框（可选）：shortcut bar 展开原生文本编辑区，长文输入/编辑用系统原生能力；发送走 bracketed paste（ESC[200~…ESC[201~]，shell 里多行不会逐行执行）；预留附件槽与 future/14 图片粘贴汇合；不做与 terminal 的实时镜像
- 多 Host 同时连接：Hosts 是会话列表，不是单槽位。已连接的 Host 行提供进入（回到离开时的 terminal/Picker）和明确的断开；点另一个未连接 Host 可另开连接，不必顶掉当前会话。屏幕上仍只显示一个 terminal
- 返回键 = 离开当前 terminal 回 Hosts，不断开 SSH/Mosh。断开只能是主动操作，或「放下手机一段时间」的可配置策略，不绑在返回上
- 收集使用中发现的其它 UX 摩擦点纳入本阶段

## 不在本步

- 发布准备（future/11）
- 通知推送（future/12）
- D-pad 长按拖动（future/13）
- 图片粘贴（future/14）
- Herdr 协议变更

## 测试

先写自动化测试并确认失败，再实现。连接手感与多地址顺序以真机手工验收为准。

### 自动化

- 点击连接后 Host 行进入 connecting 状态：状态发布时机在连接任务启动时，不是成功/失败后
- connecting 状态有可见动画（progress 指示存在且随状态出现/消失）
- 连接进行中超过阈值（默认 5 秒，可注入时钟）出现取消按钮；5 秒内连上则不出现
- 点取消：本次连接尝试被中止（认证/引导/transport 各阶段均可取消），Host 行回到 idle；已建立的既有会话不受影响；取消后再次连接可正常发起
- 取消不产生半开连接：底层 SSH/Mosh 任务被取消并清理（沿用阶段 9 的 bounded close 语义）
- `make test-core` 和 Mudi XCTest 通过（模拟器）

### 自动化（第二刀：Host 多地址）

- 旧单地址 Host 数据可无损迁移为单元素地址列表；Host ID、凭据引用、端口和信任记录不丢失；列表增删排序可持久化，不能保存空列表或空地址。
- 严格按用户顺序串行尝试地址；每地址网络建立超时有界且可注入时钟测试，失败清理后才尝试下一个，成功后不再尝试其余地址。
- 只对可恢复的网络连接失败尝试下一地址；认证失败、主机密钥不匹配和用户拒绝信任不能被自动跳过。短超时不计入等待用户输入/信任确认的时间。
- 凭据与 TOFU 按稳定 Host 身份共享；同一公钥换地址不重复确认，不同公钥仍必须报错，不能静默信任。
- 默认遵守手动地址顺序；启用智能提升后才优先上次成功地址，不改写用户保存的排序；已删除地址不能再被提升。
- 当前尝试地址、最终成功地址可见且与实际 SSH/Mosh/bootstrap/discovery 所用目标一致；重连与 Leave 不得误用列表首地址。
- 取消覆盖整个地址尝试序列，取消后不继续下一地址；过期尝试不能覆盖新连接结果；全部失败给出明确结果。
- 现有 connecting/Cancel、单地址连接、Mosh 漫游、Picker 高亮和滚动回归测试保持通过。

### 手工（出口，第一刀）

- 真机点击连接：立即看到连接动画；慢速网络下约 5 秒后出现取消
- 点取消后回到 Host 列表，无错误残留；立即重连可成功
- 正常速度连接不出现取消按钮

### 手工（出口，第二刀：Host 多地址）

- 编辑同一 Host 的 LAN/Tailscale 地址、增删拖动排序后重启仍保持；已有单地址 Host 可照常连接。
- 首地址不可达时在有界时间内尝试下一地址，界面显示实际目标；切换网络后能使用可达地址连接。
- 地址尝试中取消、立即重试正常；同机同密钥换地址不重复要求信任；错误密钥不能被自动接受。
- 智能提升关闭时尊重手动顺序，开启时才优先上次成功地址。

## 切片

- Host 行 connecting 状态模型：连接任务启动即发布，成功/失败/取消时收敛；可注入时钟驱动取消按钮的 5 秒阈值。
- Host 列表 UI：connecting 动画（进度指示）、取消按钮的出现/消失、取消后回到 idle。
- 取消链路：贯穿 SSH 认证/bootstrap、Herdr discovery、Mosh bootstrap/attach 各阶段，取消后清理底层任务（沿用阶段 9 bounded close 语义），不产生半开连接。
- 测试先行：状态时机、阈值出现/消失、取消清理、再次连接可用；模拟器全量 + 真机手工验收。

### 第二刀：Host 多地址

- 先补上述红测试，再实现数据迁移、表单增删排序、串行网络失败回退、Host 级凭据/信任身份与实际目标展示。
- 智能提升为可选开关且默认关闭；保持原始手动顺序。
- 本刀不实现多 Host 同时连接、返回不断开或 compose；具体网络短超时与地址端口模型有歧义时先请求确认。

## 完成后

归档为 `archive/10-ux-polish-2.md`，将 `future/11-release.md` 提升为 `active_plan.md`。


## 用户追加：Figma UI polish（ui-polish 分支）

**出口：** 按 2026-10-03 用户提供的 Figma `Bs8ZxjukT714hydSC9WejI` 实现非 Agent 的明暗界面；保留现有 SSH/Mosh/Herdr wire 与会话语义。此独立分支不归档 Phase 10，不合并、不推送。

**范围内：** 设计色彩/字体/原始图标；主机列表及连接反馈；主机编辑；Pane Picker 的搜索、状态筛选、项目分组及本地收藏/最近使用；终端导航、可滚动快捷栏、Ctrl/反向 Tab、compose/history；可拖动/锁定 D-Pad；拇指快捷弧及槽位/左右手/触感/练习设置；现有重连状态的呈现。

**不在本轮：** Pi/Agent 面板、工具协议适配；跨 Host 会话实现；future 项目；远端协议与连接生命周期变更。

**自动化（先红后绿）：**
- `UIPolishTests.testHostsUseFigmaCanvasInBothAppearancesAndKeepHostAction`：明暗真实渲染使用设计 canvas，主机入口仍传递正确 Host。
- `UIPolishTests.testPickerOffersSearchAndStateFiltersWithoutLosingCurrentPane`：真实 Picker 展示搜索与状态筛选，当前 pane 身份标记保留。
- `UIPolishTests.testShortcutBarHasScrollableHistoryComposeAndPinnedNavigation`：历史/compose 可用，跳转/键盘固定可达。
- `UIPolishTests.testDPadLockKeepsPositionButDoesNotDisableKeys`：锁定禁止拖动，方向键仍可用。
- `UIPolishTests.testDoubleTapDragIsInstalledWithoutReplacingTextSelection`：双击拖选手势安装且不取代单指文本选择。
- `UIPolishTests.testArcPreferencesRoundTripAndOldPreferencesRemainCompatible`：槽位、左右手和触感可保存，旧设置解码兼容。
- `UIPolishRenderTests.testHostLargeTitleRemainsVisibleInBothAppearances`：真实渲染中原生大标题在明暗模式均可见，避免导航背景遮挡。
- 补充 `UIPolishInteractionTests` 覆盖搜索/筛选的 pane 身份、收藏/最近使用持久化、快捷弧边缘几何/返回原点取消/真实输入、D-Pad 自定义角键、compose bracketed paste。
- 回归：`make test-core`、Mudi XCTest（模拟器）；仅更新被新设计明确替代的旧外观合同。

**手工：** 对照 Figma 核对主机、编辑、Picker、终端、拇指弧、D-Pad 的明暗渲染；iPhone 与 iPad 检查可达范围、滚动与键盘空间。真实主机/设备交互出口保留待用户验收。

**切片：** 合同/红测 → 设计系统与资源 → 主机/Picker/编辑 → 终端与输入浮层 → 模拟器验证。


**验证记录（2026-10-03）：**
- 先跑红 6 项 UI 合同，再实现；新增真实输入、持久化、几何、后台颜色解析、D-Pad 角键及原生标题可见性覆盖。
- `make test-core`：13 项通过；日志 `/tmp/mudi-build-core.log`。
- iPhone 17 Pro / iOS 27 模拟器全量 XCTest：353 项通过、0 失败、0 跳过；`/tmp/mudi-build/UIPolish-Verified2.xcresult`。
- iPad Pro 11 / iOS 27 模拟器 UI、交互、渲染、快捷栏及输入空间检查：32 项通过、0 失败；`/tmp/mudi-build/UIPolish-iPadVerified.xcresult`。
- 核对 41 个原始 SVG 的编译尺寸，以及主机、编辑、Picker、终端、D-Pad、拇指弧和设置的 14 张明暗渲染；预览位于 `/tmp/mudi-build/ui-preview/`。
- 原生大标题被导航背景遮挡的问题已修复并有像素断言；既有地址竞速测试补充了 fake clock 注册同步，保持原有预算及结果合同。
- 真机与真实 Host 交互尚未验收；此记录不代表 Phase 10 手工出口完成，Agent 工具适配仍暂缓。

**用户反馈修正（2026-10-03）：** D-Pad 删除/清除角键采用与方向键相同的单层轮廓，取消额外虚线；拇指快捷弧全部保持等大，选中仅通过颜色和标签反馈。先跑红选中前后目标几何稳定测试，再移除放大；角键自定义与终端输入合同沿用现有覆盖。

- 修正验证：Pro Max 相关 UI/交互/明暗渲染 20 项通过，Core 13 项通过；选中前后所有目标的可见位置与尺寸保持一致。结果 `/tmp/mudi-build/UIPolish-Uniform-Green.xcresult`，新截图 `/tmp/mudi-build/ui-preview-uniform/`。
