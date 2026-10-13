# Ghostty VT 真机安装与自动化验证

观察日期：2026-10-14。用户明确授权真机安装和测试；此前计划中的设备禁止仅适用于未获授权阶段。

## 构建来源与额外修复

基于已通过独立 Review 的 `e2f56c277bbbe09141f9875527fe674558612174`，加上本次偏好兼容初始化修复、选择焦点修复、回归测试及计划测试条目。安装产物不是该已审查 HEAD 的完全相同源码；两项后续补丁由宿主复核、tests-first 验证，用户已授权提交并创建 PR，尚未经独立 qing 复审。

真机构建编译器报告 `Preferences.swift` 的 `appearance/fontSize` 兼容 initializer 无限递归。新增 `Phase4SettingsTests.testLegacyAppearanceAndFontInitializerKeepsDefaultsWithoutRecursion` 后，在模拟器实际发生测试进程异常退出，xcodebuild exit 65。明确传入 `terminalEngine: .swiftTerm` 后转调完整 initializer；偏好与 App mount 窄回归 9/9 通过，exit 0。

## 设备与签名

- Mimikyu，iPhone 17 Pro Max，iOS 27.2，UDID `00008150-001265CE0E99401C`。
- 复用 `/tmp/mudi-build-device`，现有开发证书及包含该设备的 wildcard profile；Team 由已存在 profile 读取，仅以命令行 build override 传入，未改项目或用户配置。
- 初始 codesign `errSecInternalComponent`：现有签名 keychain 锁定。使用既有本地凭据解锁后同一证书正常签名，未更改权限或创建证书/profile。
- 安装版本 `1.0 (26101401)`，bundle `com.mimiqdev.mudi`。该开发版本更新同 bundle 的原安装，未卸载；正常启动截图保留两台已保存主机。

## 实际验证

- 真机 XCTest：GhosttyVTRendererTests、GhosttyVTSessionTests、GhosttyVTUIKitInputTests、GhosttyVTHostTests、GhosttyVTAppMountTests、GhosttyVTViewportTests、GhosttyVTThemeTests、Phase4SettingsTests，**48 tests / 0 failures，exit 0**。
- 真实 VT、绘制、UIKit API、App opt-in/真实错误回退、剪贴板/颜色及跨 session 重复行为在真机测试进程运行。PTY 为测试记录通道，不等于远端 SSH/Mosh/Herdr 人工验证。
- 修复后完整模拟器回归：**418 tests / 0 failures，exit 0**，复用 `/tmp/mudi-build`。
- 安装及正常 App 启动成功；启动后进程查询可见 Mudi，截图主机页正常。默认仍 SwiftTerm，未修改用户的 renderer 偏好。
- `git diff --check` 通过；未将未提交源码的执行结果冒充精确 committed HEAD 的 qing verify。

证据路径（本机临时文件）：

- `/tmp/mudi-device-prefs-red.log`、`/tmp/mudi-device-prefs-green.log`。
- `/tmp/mudi-device-ghostty-tests.log`；`/tmp/mudi-build-device/Logs/Test/Test-Mudi-2026.10.14_00-08-36-+0800.xcresult`。
- `/tmp/mudi-device-final-regression.log`。
- `/tmp/mudi-ghostty-device-install.json`、`/tmp/mudi-ghostty-device-launch.json`、`/tmp/mudi-ghostty-device-processes.json`、`/tmp/mudi-ghostty-device-app.json`。
- `/tmp/mudi-ghostty-device-launch.png`。

## 真机反馈：取消选区召回键盘（26101402）

用户反馈收起键盘后长按选中 Agent 输出，再点击取消选择会弹键盘。生产 `focusTerminal` 无条件清选区后 becomeFirstResponder；新增 `testSelectionDismissTapPreservesHiddenKeyboardAndExplicitFocusStillWorks` 调用实际 tap selector，实际观察到隐藏键盘/焦点回调断言失败（exit 65）。

修复：存在选区时只清选择并返回，保留原第一响应者状态；普通无选区点击仍可进入输入，显式键盘按钮及 focus gate 保留。单击 recognizer 依赖选择 long press 失败，避免长按结束兼认单击。生产动作测试覆盖隐藏/显示键盘、选择取消、独立普通点击、键盘按钮及禁止焦点；实际长按识别及系统菜单交互仍需要用户复测。

修复后模拟器全回归 **419/419**、Mimikyu 真机专项 **49/49** 均 exit 0；日志 `/tmp/mudi-selection-focus-{red,validation}.log`。`1.0 (26101402)` 已安装并正常启动，证据 `/tmp/mudi-selection-focus-{install,launch}.json`。此后续补丁尚未经独立 qing 复审；运行日志是实际执行证据，不把提交前运行冒充 committed HEAD 的 qing verify。

## 未验收与手工入口

手机设置 → Terminal → Renderer → Ghostty VT (Experimental)，下次挂载生效；退出终端再连接。真实中日韩系统 IME、实体键盘、现有远端 Host、真实前后台/多 Host 切换、复杂手势与性能尚未执行人工验收。接口级真机测试不能替代这些项目。用户认可当前完整度并授权提交、推送及创建 PR；Phase 15 完整出口仍未验收，不归档、不合并。主 checkout Phase16 改动保持不动。
