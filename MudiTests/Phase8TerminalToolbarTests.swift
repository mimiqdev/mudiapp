import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

@MainActor
final class Phase8TerminalToolbarTests: XCTestCase {
    func testTransportBadgePolicyUsesASeparateTopCornerForEachIdiom() {
        let phone = TerminalTransportBadgePlacementPolicy.resolved(for: .phone)
        let pad = TerminalTransportBadgePlacementPolicy.resolved(for: .pad)

        XCTAssertEqual(phone.corner, .topTrailing)
        XCTAssertEqual(pad.corner, .topTrailing)
        XCTAssertGreaterThan(phone.topInset, 0)
        XCTAssertGreaterThan(pad.topInset, 0)
        XCTAssertGreaterThanOrEqual(phone.horizontalInset, 8)
        XCTAssertGreaterThanOrEqual(pad.horizontalInset, 8)
        XCTAssertNotEqual(phone, pad)
    }

    func testTransportBadgeStyleUsesThemeBlueAndComputedContrast() throws {
        let lightTheme = try XCTUnwrap(
            TerminalThemeRegistry.theme(named: "Mudi Default Light")
        )
        let darkTheme = try XCTUnwrap(
            TerminalThemeRegistry.theme(named: "Solarized Dark")
        )
        let lightStyle = TerminalTransportBadgeStyle.resolved(for: lightTheme)
        let darkStyle = TerminalTransportBadgeStyle.resolved(for: darkTheme)

        XCTAssertEqual(lightStyle.fill, lightTheme.ansi16[4])
        XCTAssertEqual(darkStyle.fill, darkTheme.ansi16[4])
        XCTAssertNotEqual(
            lightStyle.fill,
            darkStyle.fill,
            "Different themes must produce different badge fills"
        )

        for (theme, style) in [(lightTheme, lightStyle), (darkTheme, darkStyle)] {
            let foregroundContrast = TerminalTransportBadgeStyle.contrastRatio(
                between: theme.defaultForeground,
                and: style.fill
            )
            let backgroundContrast = TerminalTransportBadgeStyle.contrastRatio(
                between: theme.defaultBackground,
                and: style.fill
            )
            let expectedText = foregroundContrast >= backgroundContrast
                ? theme.defaultForeground
                : theme.defaultBackground

            XCTAssertEqual(
                style.text,
                expectedText,
                "Badge text must use the more contrasting theme anchor"
            )
            XCTAssertEqual(
                style.contrastRatio,
                max(foregroundContrast, backgroundContrast),
                accuracy: 0.0001
            )
        }
    }

    func testTerminalToolbarUsesSurfaceBadgeAndSettingsSheetForSharedPreferences() async throws {
        let store = Phase7PreferencesStore()
        let model = RootViewModel(
            coordinator: makeMissingPhase2Application(),
            preferencesStore: store
        )
        let harness = Phase7TerminalScreenHarness(
            host: phase2Host(),
            session: SSHShellSession(connectedChannel: Phase4OutputChannel()),
            onDisconnect: {},
            onOpenPanePicker: {},
            settingsModel: model
        )
        defer { harness.close() }

        guard let terminal = await harness.terminal() else {
            XCTFail("The terminal view did not mount")
            return
        }
        let badgeView = await waitForView(
            "terminal-transport-badge",
            in: harness
        )
        XCTAssertNotNil(badgeView)
        XCTAssertNil(
            view(with: "active-transport", in: harness),
            "Transport must no longer occupy a toolbar item"
        )
        let badge = try XCTUnwrap(badgeView)
        XCTAssertEqual(badge.accessibilityLabel, "Active transport: SSH")

        let settings = await waitForView(
            "terminal-settings",
            in: harness
        )
        XCTAssertNotNil(settings)
        let settingsButton = try XCTUnwrap(settings)
        XCTAssertTrue(phase7Activate(settingsButton))
        let appearanceSheetVisible = await waitForAppearanceControls(in: harness)
        XCTAssertTrue(
            appearanceSheetVisible,
            "The in-terminal sheet must reuse the terminal appearance controls"
        )

        let selectedTheme = try XCTUnwrap(
            TerminalThemeRegistry.theme(named: "Solarized Dark")
        )
        model.updateThemeSelection(.fixedDark(selectedTheme.name))
        let appliedLive = await waitForTheme(
            selectedTheme.name,
            on: terminal
        )
        XCTAssertTrue(appliedLive, "Theme changes must apply to the open terminal")

        var persisted: TerminalPreferences?
        for _ in 0..<100 {
            persisted = try? await store.load()
            if persisted?.themeSelection == model.preferences.themeSelection {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            persisted?.themeSelection,
            model.preferences.themeSelection,
            "The terminal sheet and main Settings must use the same persistence model"
        )
    }

    private func view(
        with identifier: String,
        in harness: Phase7TerminalScreenHarness
    ) -> UIView? {
        if let view = phase7View(with: identifier, in: harness.controller.view) {
            return view
        }
        guard let window = harness.controller.view.window else { return nil }
        return phase7View(with: identifier, in: window)
    }

    private func waitForView(
        _ identifier: String,
        in harness: Phase7TerminalScreenHarness
    ) async -> UIView? {
        for _ in 0..<200 {
            if let view = view(with: identifier, in: harness) {
                return view
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return view(with: identifier, in: harness)
    }

    private func waitForAppearanceControls(
        in harness: Phase7TerminalScreenHarness
    ) async -> Bool {
        for _ in 0..<200 {
            if view(with: "terminal-theme-picker", in: harness) != nil,
               view(with: "terminal-font-picker", in: harness) != nil,
               view(with: "terminal-theme-preview", in: harness) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return view(with: "terminal-theme-picker", in: harness) != nil
            && view(with: "terminal-font-picker", in: harness) != nil
            && view(with: "terminal-theme-preview", in: harness) != nil
    }

    private func waitForTheme(
        _ name: String,
        on terminal: ShellTerminalView
    ) async -> Bool {
        for _ in 0..<200 {
            if terminal.appliedTheme?.name == name { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return terminal.appliedTheme?.name == name
    }
}
