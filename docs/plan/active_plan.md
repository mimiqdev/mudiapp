# Active plan — Phase 15: 官方 Ghostty VT + Mudi 自有 iOS renderer

**状态：** 用户已确认路线 2 与下列首轮合同，批准分阶段实现，不是仅调研。保留阶段 A `297dfab1`；本工作树基于 `0e5250d37e21f2f7345940a52f4044ed789fc90d`。主 checkout 的 Phase 16 未提交/未验收，暂停、不搬运、不归档。

## 出口

先交付可运行的正确性垂直切片：真实 libghostty-vt 分片 feed → full/partial/clean 行状态 → Mudi UIKit/CoreText/CoreGraphics 绘制，模拟器有可观察的 cell/geometry/像素证据。然后推进受控 App opt-in A/B；SwiftTerm 始终默认，失败明确回退到原 session，偏好变更只在下次挂载生效。可阶段性交接，但不得将未完成的高级交互或未执行的真机验收报为全量迁移完成。

## 范围内

- 固定 `caelyreth/libghostty-vt-spm@1f5446ec78f38546f1aee8f73067b9a4f7703262`（0.2.1）：官方 Ghostty VT upstream `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`；binary URL/checksum/许可证保留在 `docs/research/libghostty-ios.md` 并在接入处记录。这是官方 VT 核心的第三方 Swift 分发，不是官方 full renderer。
- VT 负责解析/状态/输入编码；Mudi 使用 CoreText 排版与现有 Nerd Font fallback、CoreGraphics 画背景/字形/光标。严格按 column/width/spacer 和 row index 更新；不按 String.count 猜列宽。
- 网格按真实可见 viewport（扣除快捷栏/键盘 chrome）和字体尺寸计算，空/极端尺寸有界；resize/full 重建、partial 保留未改行、clean 不清屏。
- 后续 A/B 接入只换 terminal host/adapter/view，走现有 `SSHShellSession` output/send/resize；处理 VT `drainEvents` 的 PTY 回复、bell/title。快捷栏/Ctrl/D-pad/Composer/ThumbArc 逐步迁移中立接口，软件键盘/IME 由 UIKit 输入适配负责。

## 不在本步

- 不采用 Lakr full-engine iOS fork、不重写 libghostty 或 ANSI/VT 状态机；不保留隐藏 SwiftTerm 替实验引擎解析/绘制。
- 不改变默认引擎、不移除 SwiftTerm、不承诺性能更快；Metal/图集/批绘等优化留待有数据后的切片。
- 不改 SSH/Mosh/Herdr transport/wire、TOFU、idle、认证、重连策略；不实施 Phase 16 或其他 future 工作。
- 本轮不安装用户手机、不运行 device XCTest、不自动发版/归档/合并/push。真机手工出口待另行确认。

## 测试

**合同状态：用户已确认。** 每个增量先写窄测试、观察正确原因的红，再实现绿；只以真实 VT/模拟器绘制证据报通过，不能用 mock renderer/stub 替代。

### 自动化（首轮批准合同）

- `testFreshInstallKeepsSwiftTermAsDefault`：原偏好/新安装保持 SwiftTerm；实验选择不偷偷改 transport 或重复拨号。
- `testFragmentedVTOutputRetainsUnicodeAndColorCells`：真实 VT 分片 feed 形成可读屏幕；中文宽字符/组合字符、ANSI16/256/真彩有真实 cell 数据。
- `testCoreTextDrawsVTCellsFallbackAndCursor`：实际 UIKit view/image 或像素证明文本、Nerd/Unicode fallback、背景和光标绘制；布局遵循 VT 列宽及 spacer。
- `testFullPartialAndCleanUpdatesRetainUnchangedRows`：真实 full/partial/clean 状态按行应用；resize full 重建网格，clean 不清屏。
- `testVisibleViewportResizeIsBoundedAndPreservesState`：可见 viewport/字体决定 PTY 行列；空、非有限、极端尺寸有界，不误清无关状态。
- `testInputAndVTRepliesUseExistingPTY`：现有控键、文本提交、粘贴/Enter及 VT 查询回复落到同一 session，保持字节语义；marked text 未提交不发送，提交一次。
- `testOptInMountAndFallbackKeepOriginalSession`：首次挂载、快捷栏/键盘预留、resize 用真实可见网格；不重复连接，真实初始化错误明确回退；已发送/已有输出不静默丢失。偏好变更不替换活动 view/state，明确下次挂载生效。
- `testScrollSelectionThemeAndLifecycleOwnership`：local scrollback/selection/clipboard 与 Herdr remote scroll/Mosh wheel 分清所有权；主题/字体、session 替换、隐藏/显示的状态与焦点可验证。API 缺口如实报告，不用 stub 宣称完整。
- 回归：Phase 4/7/8 交互、快捷栏、layout/theme/font、Herdr frame 与 Mosh data-plane；每个切片跑窄测试，最终补模拟器全套。

### 手工（尚未执行，本轮不授权设备安装）

- 后续获确认后在 iOS 17+ 真机验证中文/日文/韩文 IME、软/硬键盘、selection/copy/paste/local scrollback、持续绘制/resize/大 TUI、主题字体。
- 现有 SSH/Mosh/Herdr Host 的后台返回、多 Host/session 替换、远端 scroll/wheel：保留内容与焦点，不重复连接、不改协议/安全策略。

## 切片

仅在相应窄测试存在并观察红后实施该切片：

1. 真实 VT + 保留行状态 + CoreText/CoreGraphics view（正确性第一）；依赖固定来源/许可证，模拟器绘制与 resize 证据。
2. 中立输入/session adapter：同 PTY 输出、查询回复、输入编码、UIKit marked text/提交；有序输出、错误可观察。
3. App opt-in 挂载及设置、真实失败回退、快捷栏 chrome/中立宿主接口；默认与活动 session 不变。
4. selection/local scrollback/clipboard、remote scroll/wheel、主题字体/lifecycle 完善；按实测能力记录尚未实现项，最终模拟器完整回归。

## 完成后

- 保持本计划为 active；首个可用切片可提交并阶段性交接，未满足全部自动化/手工出口不得归档。
- 归档名 `docs/plan/archive/15-libghostty-ios-spike.md`，仅用户确认且出口验收后。
- 下一项 `docs/plan/future/16-agent-actions.md`；主 checkout 合流并确认前保持暂停。
