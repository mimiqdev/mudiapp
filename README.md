# Mudi

Mudi 是面向 iPhone 和 iPad 的远程终端客户端，用来连接开发机上的 Herdr。产品定义见 [PRD](docs/PRD.md)，当前开发步骤见 [active plan](docs/plan/active_plan.md)。

## 技术栈

- Swift 6、SwiftUI + UIKit
- SwiftTerm：terminal emulator 与 iOS terminal view
- Citadel：基于 SwiftNIO SSH 的 SSH client
- swift-mosh：纯 Swift Mosh protocol / transport
- Swift Package Manager：源码依赖
- XcodeGen：从 `project.yml` 生成 Xcode project

完整取舍见 [架构说明](docs/ARCHITECTURE.md) 和 [第三方依赖](docs/THIRD_PARTY.md)。

## 本地启动

需要 macOS、Xcode 和 [mise](https://mise.jdx.dev/)。XcodeGen 由 `mise.toml` 固定为 2.46.0。

```sh
brew install mise
eval "$(mise activate zsh)"  # 写入 ~/.zshrc 后可省略
mise trust
mise install
make bootstrap
open Mudi.xcodeproj
```

选择 `Mudi` scheme 和任意 iPhone / iPad simulator 运行。首次打开时，Xcode 会通过 Swift Package Manager 拉取依赖。

纯 Swift 的领域模型可以独立验证：

```sh
make test-core
```

bundle identifier 是 `dev.mudi.mobile`。
