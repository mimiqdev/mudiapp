# Herdr Mobile Client

Herdr Mobile Client 是面向 iPhone 和 iPad 的 Herdr 远程终端客户端。产品定义见 [PRD](docs/PRD.md)，初步开发节奏见 [开发计划](docs/DEVELOPMENT_PLAN.md)。

## 技术栈

- Swift 6、SwiftUI + UIKit
- SwiftTerm：terminal emulator 与 iOS terminal view
- Citadel：基于 SwiftNIO SSH 的 SSH client
- swift-mosh：纯 Swift Mosh protocol / transport
- Swift Package Manager：源码依赖
- XcodeGen：从 `project.yml` 生成 Xcode project

完整取舍见 [架构说明](docs/ARCHITECTURE.md) 和 [第三方依赖](docs/THIRD_PARTY.md)。

## 本地启动

需要 macOS、Xcode 以及 XcodeGen。

```sh
brew install xcodegen
make bootstrap
open HerdrMobile.xcodeproj
```

选择 `HerdrMobile` scheme 和任意 iPhone / iPad simulator 运行。首次打开时，Xcode 会通过 Swift Package Manager 拉取依赖。

纯 Swift 的领域模型可以独立验证：

```sh
make test-core
```

`dev.herdr.mobile` 是冷启动阶段的临时 bundle identifier，接入签名和发布配置时需要替换。
