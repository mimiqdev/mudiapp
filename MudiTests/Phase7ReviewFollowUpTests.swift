import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

/// Review round 2 follow-up coverage: the Settings sheet color-scheme
/// refresh (f3 item).
@MainActor
final class Phase7ReviewFollowUpTests: XCTestCase {
    // MARK: f3a - Settings sheet color-scheme refresh

    func testSettingsSheetResolvesDarkAppearance() async throws {
        let fixture = makeSettingsSheet()
        fixture.model.updateAppearance(.dark)
        defer { fixture.window.isHidden = true }

        let darkApplied = await pollUntil {
            fixture.window.overrideUserInterfaceStyle == .dark
        }
        XCTAssertTrue(
            darkApplied,
            "The open Settings sheet must resolve the Dark appearance"
        )
        XCTAssertEqual(fixture.model.preferences.appearance, .dark)
    }

    func testSettingsSheetRefreshesWhenSwitchingBackToSystem() async throws {
        let fixture = makeSettingsSheet()
        // Capture the device system theme before any override so the
        // System phase can assert the resolved trait regardless of the
        // device theme.
        let systemStyle = fixture.window.traitCollection.userInterfaceStyle
        fixture.model.updateAppearance(.dark)
        defer { fixture.window.isHidden = true }

        let darkApplied = await pollUntil {
            fixture.window.overrideUserInterfaceStyle == .dark
        }
        XCTAssertTrue(darkApplied)

        // Switching back to System must refresh the already-presented
        // sheet instead of leaving it stuck in Dark: the override bridge
        // clears the window pin and the trait resolves to the system
        // theme.
        fixture.model.updateAppearance(.system)
        let restoredToSystem = await pollUntil {
            fixture.window.overrideUserInterfaceStyle == .unspecified
                && fixture.controller.view.traitCollection.userInterfaceStyle
                    == systemStyle
        }
        XCTAssertTrue(
            restoredToSystem,
            "Switching Dark→System must refresh the presented Settings sheet"
        )
    }

    func testTerminalAppearanceSheetFollowsSelectedAppAppearance() async {
        let model = RootViewModel(
            coordinator: makeMissingPhase2Application(),
            preferencesStore: Phase7PreferencesStore()
        )
        let harness = Phase7TerminalScreenHarness(
            host: phase2Host(),
            session: SSHShellSession(connectedChannel: Phase4OutputChannel()),
            onDisconnect: {},
            settingsModel: model
        )
        defer { harness.close() }

        var settingsView: UIView?
        for _ in 0..<200 {
            settingsView = phase7View(
                with: "terminal-settings",
                in: harness.controller.view
            )
            if settingsView != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let settingsView else {
            XCTFail("The terminal settings control did not mount")
            return
        }
        XCTAssertTrue(phase7Activate(settingsView))

        var sheetWindow: UIWindow?
        for _ in 0..<200 {
            sheetWindow = harness.controller.presentedViewController?
                .viewIfLoaded?.window
            if sheetWindow != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let sheetWindow else {
            XCTFail("The terminal appearance sheet did not present")
            return
        }

        model.updateAppearance(.dark)
        let darkApplied = await pollUntil {
            sheetWindow.overrideUserInterfaceStyle == .dark
        }
        XCTAssertTrue(
            darkApplied,
            "The terminal appearance sheet must follow the app's Dark setting"
        )

        model.updateAppearance(.system)
        let restoredToSystem = await pollUntil {
            sheetWindow.overrideUserInterfaceStyle == .unspecified
        }
        XCTAssertTrue(
            restoredToSystem,
            "Switching the terminal appearance sheet back to System must clear its override"
        )
    }

    /// Mirrors the real sheet structure in RootNavigationView: the
    /// observing view owns the scheme modifiers so updates propagate.
    private struct SettingsSheetFixture {
        let window: UIWindow
        let controller: UIHostingController<SettingsSheetProbe>
        let model: RootViewModel
    }

    private func makeSettingsSheet() -> SettingsSheetFixture {
        let model = RootViewModel(
            coordinator: makeMissingPhase2Application(),
            preferencesStore: Phase7PreferencesStore()
        )
        let window = Phase7TerminalScreenHarness.makeWindow()
        let controller = UIHostingController(
            rootView: SettingsSheetProbe(model: model)
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.loadViewIfNeeded()
        Phase7TerminalScreenHarness.kickAppearance(of: controller)
        return SettingsSheetFixture(
            window: window,
            controller: controller,
            model: model
        )
    }

    private struct SettingsSheetProbe: View {
        @ObservedObject var model: RootViewModel

        var body: some View {
            NavigationStack {
                SettingsView(model: model)
            }
            .preferredColorScheme(model.preferences.appearance.colorScheme)
            .background(
                InterfaceStyleOverride(
                    colorScheme: model.preferences.appearance.colorScheme
                )
            )
        }
    }

    private func pollUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
