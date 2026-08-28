# 冷启动架构

## 技术选择

App 使用 SwiftUI 搭建页面和状态驱动的导航，terminal 通过 `UIViewRepresentable` 承载原生 terminal view。根导航采用 `NavigationSplitView`：iPad 展示多栏结构，iPhone 和窄尺寸窗口自动折叠为栈式导航。

当前骨架使用 SwiftTerm，方便尽快建立可运行切片。技术验证阶段会加入 GhosttyKit 对照，重点比较大型 TUI 刷新性能、Unicode、selection、触屏输入、外接键盘和二进制集成成本。最终选型应保留相同的 terminal adapter 接口，避免影响 SSH、Mosh 和 Herdr 层。

最低系统版本暂定 iOS / iPadOS 17。这样可以使用现代 Swift concurrency 和 Observation，同时保留合理的设备覆盖。正式发布前再根据目标用户设备调整。

## 模块边界

```text
HerdrMobile App
├── App                 应用入口和根导航
├── Features
│   ├── Hosts           Host 选择与配置
│   ├── HerdrBrowser    workspace / tab / pane 导航
│   └── Terminal        terminal 容器和输入 UI
├── Infrastructure
│   ├── SSH             Citadel 适配
│   ├── Mosh            swift-mosh 适配
│   └── Persistence     Keychain 与普通配置存储
└── Packages/HerdrKit   领域模型和跨层协议
```

`HerdrKit` 保持为纯 Swift package，不依赖 SwiftUI、SwiftTerm 或具体网络库。业务层面只认识 transport 和 session 抽象，SSH 与 Mosh 的实现细节留在 Infrastructure。

## 第一个可运行切片

冷启动阶段优先完成一条端到端路径：

```text
Host 配置
→ Citadel 建立 SSH
→ 请求 PTY / shell
→ 字节流接入 terminal adapter
→ 键盘输入写回 SSH channel
→ terminal resize 同步远端
```

SSH terminal 路径验证成功后，使用同一套 SSH 认证启动远端 `mosh-server`，再把返回的 UDP port 和 session key 交给 swift-mosh。Herdr discovery、状态恢复、SSH 和 Mosh 共享领域模型与 terminal session 接口。

## Herdr 自动发现与 attach

App 建立 SSH bootstrap channel 后执行只读 discovery：

```text
定位 herdr binary
→ 读取 herdr version
→ herdr session list --json
→ 0 个 session：显示空状态与普通 terminal 入口
→ 1 个 session：直接查询并展示 workspace / tab / pane / agent
→ 多个 session：展示 session 列表，选择后查询其内容
→ 用户选择 pane 后打开 terminal session control stream
```

SSH 和 Mosh 模式都使用 SSH bootstrap channel 完成 discovery。Mosh 负责后续交互 terminal 的移动网络 transport，App 不通过 Mosh terminal 输出解析 Herdr 结构。

Herdr 的 CLI wrappers 和 socket API 共用同一套控制面。V1 先通过 SSH exec channel 调用 CLI，避免在移动端复刻 socket path、协议版本和 named session 解析。需要长连接事件订阅时，再增加 SSH tunnel 到远端 Unix socket 的适配。

交互式 pane 使用 `herdr terminal session control <target> --cols <n> --rows <n>`。该命令通过 stdout 输出 newline-delimited terminal frames，并从 stdin 接收 input、resize、scroll 和 release 命令，适合接入 terminal adapter。

Discovery 不会安装软件、启动新 session 或修改 agent 配置。Herdr binary 不存在时，App 显示普通 terminal 和安装指引；发现 session 后才执行后续查询。只有一个 session 时省略 session picker，pane attach 仍由用户选择触发。

Agent hook 不参与 server discovery。Herdr 默认通过进程和 terminal screen 检测常见 agent。官方 integration 可以补充 semantic state 和 native session identity，App 将其视为能力增强，不作为 V1 attach 前提。

## 数据与安全

- Host 的非敏感配置存入本地应用数据。
- 密码和私钥使用系统 Keychain，不进入 `UserDefaults`、日志或可同步的普通文件。
- 首次连接展示 host key fingerprint；后续连接校验已保存的 key。
- 日志只记录状态、耗时和错误类别，过滤 hostname、username、命令内容和密钥材料。

## 工程生成与依赖

`project.yml` 是 Xcode project 的来源，`make bootstrap` 生成本地 `.xcodeproj`。运行时依赖由 Swift Package Manager 解析。仓库保留 `Package.resolved` 的计划是在首次使用 macOS / Xcode 完成解析后提交，以固定可复现版本。
