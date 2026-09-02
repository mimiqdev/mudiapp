import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

/// Review-driven coverage for the phase 7 UX polish fixes: passive
/// permission probing, terminal bottom-row visibility under the persistent
/// bar, narrow-layout bar compression, touch cursor positioning, the
/// Settings sheet color-scheme refresh, and Continue double-tap guard.
@MainActor
final class Phase7ReviewFixesTests: XCTestCase {
    // MARK: f1 - passive permission probing

    func testSystemGateStatusIsPassiveUntilPermissionIsRequested() async {
        let gate = SystemLocalNetworkPermissionGate()

        // The passive read never starts a browse, so it cannot trigger the
        // iOS Local Network alert before the explanation screen.
        let status = await gate.status()
        XCTAssertEqual(status, .undetermined)
    }

    // MARK: f2 - bottom row visibility under the persistent bar

    func testShortcutBarInsetsTerminalBottomForRowVisibility() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let chrome = TerminalChromeView(terminalView: terminalView)
        let harness = Phase7TerminalViewHarness(
            terminalView: terminalView,
            chromeView: chrome
        )
        defer {
            harness.close()
            terminalView.stop()
        }
        harness.window.layoutIfNeeded()

        guard let bar = terminalView.shortcutBar else {
            XCTFail("The terminal must own a shortcut bar")
            return
        }
        XCTAssertEqual(
            bar.intrinsicContentSize.height,
            ShellTerminalView.shortcutBarHeight
        )
        // The bar strip is reserved by shrinking the terminal view's frame:
        // the terminal must END exactly where the bar begins (never under
        // it), so SwiftTerm lays out rows only in the visible region.
        let expectedReservation = ShellTerminalView.shortcutBarHeight
            + MudiShortcutBarCapsulePolicy.phone.bottomMargin
        XCTAssertEqual(
            terminalView.frame.maxY,
            chrome.bounds.height - expectedReservation,
            accuracy: 0.5,
            "The terminal content must end above the shortcut bar"
        )
        XCTAssertEqual(
            bar.frame.minY,
            chrome.bounds.height - expectedReservation,
            accuracy: 0.5,
            "The bar must start exactly where the terminal content ends"
        )
    }

    // MARK: f4 - narrow-layout compression

    func testShortcutBarCompressesToFit320PointWidth() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)

        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44)
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let buttons = phase7ShortcutButtons(in: bar)
        XCTAssertEqual(buttons.count, 7, "All seven items must survive a 320pt layout")
        for button in buttons {
            XCTAssertGreaterThan(
                button.bounds.width,
                0,
                "\(button.accessibilityIdentifier ?? "button") must stay visible"
            )
            XCTAssertLessThanOrEqual(
                button.frame.maxX,
                bar.bounds.width + 0.5,
                "\(button.accessibilityIdentifier ?? "button") must not clip past the bar"
            )
        }
    }

    // MARK: r2-f1 - combo popup stays inside narrow layouts

    func testComboPopupStaysInside320PointLayout() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)

        container.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44)
        ])
        container.setNeedsLayout()
        container.layoutIfNeeded()

        let popup = try XCTUnwrap(
            phase7View(with: "terminal-control-combo-popup", in: bar)
        )
        popup.isHidden = false
        container.setNeedsLayout()
        container.layoutIfNeeded()

        XCTAssertLessThanOrEqual(
            popup.frame.maxX,
            bar.bounds.width + 0.5,
            "The combo popup must never cross the container's trailing edge"
        )
        XCTAssertGreaterThanOrEqual(popup.frame.minX, 0)
        for button in phase7Buttons(in: popup) {
            XCTAssertGreaterThan(
                button.bounds.width,
                0,
                "\(button.accessibilityLabel ?? "combo") must stay visible"
            )
            XCTAssertLessThanOrEqual(
                button.frame.maxX,
                popup.bounds.width + 0.5
            )
        }
    }

    // MARK: f7 - Continue double-tap guard

    func testCompleteLocalNetworkOnboardingIgnoresDoubleTap() async throws {
        let gate = Phase7LocalNetworkPermissionGateFake(
            status: .undetermined,
            requestResult: .granted
        )
        let model = RootViewModel(
            coordinator: makeMissingPhase2Application(),
            preferencesStore: Phase7PreferencesStore(),
            localNetworkPermissionGate: gate
        )
        await model.loadPreferences()
        await model.checkLocalNetworkPermission()
        guard model.isLocalNetworkOnboardingRequired == true else {
            return XCTFail("Fresh install must present the onboarding gate")
        }

        model.completeLocalNetworkOnboarding()
        model.completeLocalNetworkOnboarding()

        var requests = 0
        for _ in 0..<200 {
            requests = await gate.requestCount()
            if requests == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            requests,
            1,
            "A fast double-tap must not start two permission probes"
        )
        let settled = await pollUntil {
            !model.isRequestingLocalNetworkPermission
                && model.isLocalNetworkOnboardingRequired == false
        }
        XCTAssertTrue(settled)
        let finalRequests = await gate.requestCount()
        XCTAssertEqual(finalRequests, 1, "The probe must run exactly once")
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
