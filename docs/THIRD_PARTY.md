# 第三方依赖

依赖优先通过 Swift Package Manager 引入。需要修改或无法通过 SPM 构建的原生代码，才放入 `Vendor/` 并记录上游 commit、patch 和许可证。

## 已声明依赖

| 组件 | 声明版本 | 用途 | 许可证 | 集成方式 |
| --- | --- | --- | --- | --- |
| SwiftTerm | 1.15.0 | VT100 / xterm emulation、iOS terminal view | MIT | SwiftPM |
| Citadel | 0.12.1 | SSH client 高层 API | MIT | SwiftPM |
| swift-mosh | 0.1.8 | Mosh protocol、UDP transport、state synchronization | MIT | SwiftPM |

Citadel 会传递引入 SwiftNIO、Swift Crypto 和一个 SwiftNIO SSH fork 等依赖，由 SwiftPM 统一解析。SSH 技术验证阶段需要检查该 fork 与 Apple 上游的差异、维护状态和安全更新路径。

## 构建工具

| 组件 | 用途 | 许可证 | 是否进入 App |
| --- | --- | --- | --- |
| XcodeGen | 从 `project.yml` 生成 Xcode project | MIT | 否 |

## Mosh 方案

首选验证对象是 swift-mosh。它是纯 Swift、MIT 许可的独立实现，支持 iOS 16+ 和 SwiftPM。仓库引入 `MoshCore` 与 `MoshBootstrap`，SSH 认证和远端 server 启动仍由连接层负责。

swift-mosh 当前处于 0.1.x 阶段，采用前必须验证：

- 与上游 `mosh-server` 的协议互操作；
- Wi-Fi / cellular roaming、丢包、NAT 和长时间空闲；
- 前后台切换后的 session 行为；
- predictive echo、Unicode 和窗口 resize；
- crypto 实现、依赖维护和安全更新路径。

### 备选：Blink libmoshios

Blink Shell 使用 `libmoshios` 在 iOS 上提供 Mosh，并维护 `blinksh/build-mosh` 构建脚本。这套方案已有长期产品实践，但基于上游 C++ Mosh、protobuf 和较旧的原生构建流程，不是可直接加入的现代 SwiftPM package。

上游 Mosh 与 Blink 均使用 GPL-3.0。选择 libmoshios 时，需要同步落实源码提供、许可证文本、patch 记录和 App Store 分发要求。Mosh 官方另有 iOS 分发说明，但仍要求遵守 GPL 的其他条款。

## 产品实现参考

以下项目用于理解可行架构，不属于仓库依赖：

### Moshi

Moshi 的公开版本记录显示 terminal engine 已从 xterm.js 切换到 Ghostty，同时使用独立的 Rust Mosh 0.2.0。官网还说明 iOS 与 Android 通过 UniFFI 共享 Rust engine。现有公开信息没有显示 Moshi 使用 libmoshios。

GhosttyKit 在这套架构中负责 VT terminal emulation、状态和渲染；Rust Mosh 负责 SSP、UDP、加密、roaming 和 session checkpoint。两者处于不同层级。Moshi 的 Rust Mosh core 暂未找到可直接复用的公开 package，因此不作为当前 third-party 候选。

### Blink Shell

Blink Shell 使用上游 Mosh 派生的 libmoshios，是 C++ / protobuf 路线的成熟参考实现。它适合用于协议行为和移动网络测试对照。
