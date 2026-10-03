import Foundation

enum ThumbArcAction: String, Codable, CaseIterable, Sendable {
    case escape, controlC, shiftTab, cursorUp, paste, jumpTo
    case tab, controlD, controlZ, controlL, cursorDown, cursorLeft, cursorRight, home, end, pageUp, pageDown, customText
    var title: String {
        switch self {
        case .escape: "Esc"
        case .controlC: "^C"
        case .shiftTab: "⇧Tab"
        case .cursorUp: "↑"
        case .paste: "粘贴"
        case .jumpTo: "跳转"
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
        case .customText: "自定义文本"
        }
    }
    var detail: String {
        switch self {
        case .escape: "退出 / 取消"
        case .controlC: "中断"
        case .shiftTab: "反向 Tab"
        case .cursorUp: "上一条历史"
        case .paste: "剪贴板"
        case .jumpTo: "打开 Pane 列表"
        case .tab: "补全"
        case .controlD: "EOF / 退出"
        case .controlZ: "挂起"
        case .controlL: "清屏"
        case .cursorDown: "下一条历史"
        case .cursorLeft, .cursorRight: "光标移动"
        case .home: "行首"
        case .end: "行尾"
        case .pageUp, .pageDown: "翻页"
        case .customText: "发送一段片段"
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
}

struct ThumbArcPreferences: Codable, Equatable, Sendable {
    static let defaults: [ThumbArcAction] = [.escape, .controlC, .shiftTab, .cursorUp, .paste, .jumpTo]
    var actions: [ThumbArcAction] = defaults {
        didSet { actions = Self.normalize(actions) }
    }
    var isLeftHanded = false
    var hapticsEnabled = true
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
    }
    private enum CodingKeys: String, CodingKey { case actions, isLeftHanded, hapticsEnabled, customText }
}
