import CoreText
import Foundation
import HerdrKit
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

actor Phase8RecordingPTY: PTYChannel {
    private var sentBytes: [[UInt8]] = []

    func send(_ bytes: [UInt8]) async throws {
        sentBytes.append(bytes)
    }

    func resize(columns _: Int, rows _: Int) async throws {}

    func close() async {}

    func snapshot() -> [[UInt8]] {
        sentBytes
    }
}

@MainActor
final class Phase8TerminalHarness {
    let terminalView: ShellTerminalView
    private let recorder: Phase8RecordingPTY
    private let session: SSHShellSession

    init(theme: TerminalTheme) {
        terminalView = ShellTerminalView(frame: .zero)
        recorder = Phase8RecordingPTY()
        session = SSHShellSession(connectedChannel: recorder)
        terminalView.session = session
        terminalView.apply(theme: theme)
    }

    var terminal: Terminal {
        terminalView.getTerminal()
    }

    func queryColor(at index: Int) async -> TerminalRGBColor? {
        let previousResponseCount = (await recorder.snapshot()).count
        terminal.feed(text: "\u{1b}]4;\(index);?\u{1b}\\")

        // ShellTerminalView forwards terminal responses through its normal
        // session send path. Give that asynchronous path a bounded window so
        // a missing response fails the palette assertion instead of hanging
        // the test process.
        var response: [[UInt8]] = []
        for _ in 0..<50 {
            response = await recorder.snapshot()
            if response.count > previousResponseCount {
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        return phase8RGBColor(
            from: response.dropFirst(previousResponseCount).flatMap { $0 }
        )
    }

    func stop() {
        terminalView.stop()
    }
}

func phase8SwiftTermColor(_ color: TerminalRGBColor) -> SwiftTerm.Color {
    SwiftTerm.Color(
        red: UInt16(color.red) * 257,
        green: UInt16(color.green) * 257,
        blue: UInt16(color.blue) * 257
    )
}

func phase8UIKitColor(_ color: TerminalRGBColor) -> UIColor {
    UIColor(
        red: CGFloat(color.red) / 255,
        green: CGFloat(color.green) / 255,
        blue: CGFloat(color.blue) / 255,
        alpha: 1
    )
}

func phase8RGBColor(from bytes: [UInt8]) -> TerminalRGBColor? {
    guard let text = String(bytes: bytes, encoding: .ascii),
          let marker = text.range(of: "rgb:")
    else {
        return nil
    }

    // OSC replies may end with either BEL or the two-byte ST sequence. Strip
    // that terminator before taking the three hexadecimal colour components.
    let payload = text[marker.upperBound...]
        .split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { character in
                character == "\u{07}" || character == "\u{1b}"
            }
        )
        .first ?? ""
    let components = payload.split(
        separator: "/",
        maxSplits: 2,
        omittingEmptySubsequences: false
    )
    let hexCharacters = "0123456789abcdefABCDEF"
    func parseHex(_ component: Substring) -> UInt16? {
        let digits = component.prefix { hexCharacters.contains($0) }
        guard !digits.isEmpty else { return nil }
        return UInt16(digits, radix: 16)
    }

    guard components.count >= 3,
          let red = parseHex(components[0]),
          let green = parseHex(components[1]),
          let blue = parseHex(components[2]),
          red % 257 == 0,
          green % 257 == 0,
          blue % 257 == 0
    else {
        return nil
    }

    return TerminalRGBColor(
        red: UInt8(red / 257),
        green: UInt8(green / 257),
        blue: UInt8(blue / 257)
    )
}

func phase8XtermColor(at index: Int) -> TerminalRGBColor? {
    guard (16...255).contains(index) else { return nil }

    if index <= 231 {
        let values: [UInt8] = [0, 95, 135, 175, 215, 255]
        let offset = index - 16
        return TerminalRGBColor(
            red: values[(offset / 36) % 6],
            green: values[(offset / 6) % 6],
            blue: values[offset % 6]
        )
    }

    let gray = UInt8(8 + (index - 232) * 10)
    return TerminalRGBColor(red: gray, green: gray, blue: gray)
}

func phase8AppBundle() -> Bundle {
    Bundle(identifier: "dev.mudi.mobile") ?? Bundle.main
}

func phase8Font(from url: URL, pointSize: CGFloat = 16) -> CTFont? {
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
        url as CFURL
    ) as? [CTFontDescriptor],
    let descriptor = descriptors.first
    else {
        return nil
    }
    return CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
}

func phase8CTFont(from font: UIFont) -> CTFont {
    CTFontCreateWithFontDescriptor(
        font.fontDescriptor,
        font.pointSize,
        nil
    )
}

func phase8Glyphs(in font: CTFont) -> (latin: CGGlyph, nerd: CGGlyph) {
    var characters: [UniChar] = [77, 0xF07B]
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    let found = CTFontGetGlyphsForCharacters(
        font,
        &characters,
        &glyphs,
        characters.count
    )
    guard found else { return (0, 0) }
    return (glyphs[0], glyphs[1])
}

func phase8TemporaryFontURL(
    source: URL,
    fileExtension: String
) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("mudi-phase8-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
}

func phase8StoredPreferencesData(
    selection: TerminalThemeSelection,
    fontFamily: String,
    fontSize: Double
) throws -> Data {
    let encodedSelection = try JSONEncoder().encode(selection)
    let selectionObject = try JSONSerialization.jsonObject(
        with: encodedSelection
    )
    return try JSONSerialization.data(withJSONObject: [
        "appearance": AppearancePreference.system.rawValue,
        "fontSize": fontSize,
        "themeSelection": selectionObject,
        "fontFamily": fontFamily,
    ])
}

func phase8JSONValue(from data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
