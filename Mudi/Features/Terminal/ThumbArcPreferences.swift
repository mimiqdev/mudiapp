import Foundation
import CoreGraphics

enum ThumbArcActivationDistance: String, Codable, CaseIterable, Sendable {
    case short, medium, long
    var title: String {
        switch self { case .short: MudiL10n.text("短"); case .medium: MudiL10n.text("中"); case .long: MudiL10n.text("长") }
    }
    var points: CGFloat {
        switch self { case .short: 22; case .medium: 28; case .long: 36 }
    }
}

enum ThumbArcAction: String, Codable, CaseIterable, Sendable {
    case escape, controlC, shiftTab, cursorUp, paste, jumpTo
    case tab, controlD, controlZ, controlL, cursorDown, cursorLeft, cursorRight, home, end, pageUp, pageDown, customText
    var title: String {
        switch self {
        case .escape: "Esc"
        case .controlC: "^C"
        case .shiftTab: "⇧Tab"
        case .cursorUp: "↑"
        case .paste: MudiL10n.text("粘贴")
        case .jumpTo: MudiL10n.text("跳转")
        case .tab: "Tab"
        case .controlD: "^D"
        case .controlZ: "^Z"
        case .controlL: "^L"
        case .cursorDown: "↓"
        case .cursorLeft: "←"
        case .cursorRight: "→"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .customText: MudiL10n.text("自定义文本")
        }
    }
    var detail: String {
        switch self {
        case .escape: MudiL10n.text("退出 / 取消")
        case .controlC: MudiL10n.text("中断")
        case .shiftTab: MudiL10n.text("反向 Tab")
        case .cursorUp: MudiL10n.text("上一条历史")
        case .paste: MudiL10n.text("剪贴板")
        case .jumpTo: MudiL10n.text("打开 Pane 列表")
        case .tab: MudiL10n.text("补全")
        case .controlD: MudiL10n.text("EOF / 退出")
        case .controlZ: MudiL10n.text("挂起")
        case .controlL: MudiL10n.text("清屏")
        case .cursorDown: MudiL10n.text("下一条历史")
        case .cursorLeft, .cursorRight: MudiL10n.text("光标移动")
        case .home: MudiL10n.text("行首")
        case .end: MudiL10n.text("行尾")
        case .pageUp, .pageDown: MudiL10n.text("翻页")
        case .customText: MudiL10n.text("发送一段片段")
        }
    }
    var glyph: String {
        switch self {
        case .escape: "esc"
        case .customText: "…"
        default: title
        }
    }
    var icon: MudiIcon? {
        switch self {
        case .shiftTab: .shiftTab
        case .cursorUp: .up
        case .paste: .arcPaste
        case .jumpTo: .arcLayers
        case .cursorDown: .down
        case .cursorLeft: .left
        case .cursorRight: .right
        case .customText: .compose
        default: nil
        }
    }
    var arcIcon: MudiIcon? {
        switch self {
        case .shiftTab: .arcShiftTab
        case .cursorUp: .arcUp
        case .paste: .arcClipboard
        case .jumpTo: .arcJump
        default: icon
        }
    }
}

struct ThumbArcPreferences: Codable, Equatable, Sendable {
    static let defaults: [ThumbArcAction] = [.escape, .controlC, .shiftTab, .cursorUp, .paste, .jumpTo]
    var actions: [ThumbArcAction] = defaults {
        didSet { actions = Self.normalize(actions) }
    }
    var isLeftHanded = false
    var hapticsEnabled = true
    var activationDistance = ThumbArcActivationDistance.medium
    var customText = ""
    init() {}
    private static func normalize(_ values: [ThumbArcAction]) -> [ThumbArcAction] {
        var seen = Set<ThumbArcAction>()
        return Array(values.filter { seen.insert($0).inserted }.prefix(6))
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let values = try container.decodeIfPresent([String].self, forKey: .actions) {
            actions = Self.normalize(values.compactMap(ThumbArcAction.init(rawValue:)))
        }
        isLeftHanded = try container.decodeIfPresent(Bool.self, forKey: .isLeftHanded) ?? false
        hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        customText = try container.decodeIfPresent(String.self, forKey: .customText) ?? ""
        activationDistance = (try container.decodeIfPresent(String.self, forKey: .activationDistance))
            .flatMap(ThumbArcActivationDistance.init(rawValue:)) ?? .medium
    }
    private enum CodingKeys: String, CodingKey { case actions, isLeftHanded, hapticsEnabled, customText, activationDistance }
}
