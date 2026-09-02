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
