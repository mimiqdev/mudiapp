import Foundation
import GhosttyVt

/// Palette math only, never a hidden SwiftTerm parser. LAB policy follows the
/// existing SwiftTerm 1.15.0 palette semantics (MIT attribution in Resources).
enum TerminalVTPalette {
    static func colors(for theme: TerminalTheme) throws -> [TerminalFrame.RGBColor] {
        guard theme.ansi16.count == 16 else { throw TerminalError.invalidPalette }
        var palette = theme.ansi16.map(\.vtColor)
        switch theme.extendedPaletteStrategy {
        case .explicit(let extended):
            guard extended.count == 240 else { throw TerminalError.invalidPalette }
            palette += extended.map(\.vtColor)
        case .xterm:
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            for index in 0..<216 {
                palette.append(.init(red: levels[index / 36], green: levels[index / 6 % 6], blue: levels[index % 6]))
            }
            palette += (0..<24).map { index in
                let gray = UInt8(8 + index * 10)
                return .init(red: gray, green: gray, blue: gray)
            }
        case .base16Lab, .base16LabHarmonious:
            var anchors = theme.ansi16.prefix(8).map(Lab.init)
            anchors[0] = Lab(theme.defaultBackground)
            anchors[7] = Lab(theme.defaultForeground)
            if anchors[7].l < anchors[0].l, theme.extendedPaletteStrategy == .base16Lab { anchors.swapAt(0, 7) }
            for red in 0..<6 {
                let r = Double(red) / 5
                let a = Lab.mix(anchors[0], anchors[1], r)
                let b = Lab.mix(anchors[2], anchors[3], r)
                let c = Lab.mix(anchors[4], anchors[5], r)
                let d = Lab.mix(anchors[6], anchors[7], r)
                for green in 0..<6 {
                    let g = Double(green) / 5
                    let first = Lab.mix(a, b, g)
                    let second = Lab.mix(c, d, g)
                    for blue in 0..<6 { palette.append(Lab.mix(first, second, Double(blue) / 5).rgb) }
                }
            }
            palette += (0..<24).map { Lab.mix(anchors[0], anchors[7], Double($0 + 1) / 25).rgb }
        }
        return palette
    }

    private struct Lab {
        var l: Double
        var a: Double
        var b: Double
        init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }
        init(_ color: TerminalRGBColor) {
            func linear(_ value: UInt8) -> Double {
                let n = Double(value) / 255
                return n > 0.04045 ? pow((n + 0.055) / 1.055, 2.4) : n / 12.92
            }
            func transform(_ value: Double) -> Double {
                value > 0.008856 ? pow(value, 1 / 3.0) : 7.787 * value + 16 / 116.0
            }
            let red = linear(color.red), green = linear(color.green), blue = linear(color.blue)
            let x = transform((red * 0.4124564 + green * 0.3575761 + blue * 0.1804375) / 0.95047)
            let y = transform(red * 0.2126729 + green * 0.7151522 + blue * 0.0721750)
            let z = transform((red * 0.0193339 + green * 0.1191920 + blue * 0.9503041) / 1.08883)
            self.init(l: 116 * y - 16, a: 500 * (x - y), b: 200 * (y - z))
        }
        static func mix(_ first: Lab, _ second: Lab, _ t: Double) -> Lab {
            .init(l: first.l + t * (second.l - first.l), a: first.a + t * (second.a - first.a), b: first.b + t * (second.b - first.b))
        }
        var rgb: TerminalFrame.RGBColor {
            func inverse(_ value: Double) -> Double {
                let cube = value * value * value
                return cube > 0.008856 ? cube : (value - 16 / 116.0) / 7.787
            }
            func quantize(_ value: Double) -> UInt8 {
                let n = value > 0.0031308 ? 1.055 * pow(value, 1 / 2.4) - 0.055 : 12.92 * value
                return UInt8(max(0, min(1, n)) * 255 + 0.5)
            }
            let y = (l + 16) / 116
            let x = inverse(a / 500 + y) * 0.95047
            let z = inverse(y - b / 200) * 1.08883
            let yy = inverse(y)
            return .init(red: quantize(x * 3.2404542 - yy * 1.5371385 - z * 0.4985314),
                         green: quantize(-x * 0.9692660 + yy * 1.8760108 + z * 0.0415560),
                         blue: quantize(x * 0.0556434 - yy * 0.2040259 + z * 1.0572252))
        }
    }
}
