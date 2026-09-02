import HerdrKit
import SwiftUI
import UIKit
import XCTest
@preconcurrency import SwiftTerm
@testable import Mudi

@MainActor
final class Phase7UXPolishTests: XCTestCase {
    func testFirstLaunchWithoutLocalNetworkPermissionShowsExplanationBeforeHosts() async throws {
        let coordinator = makeMissingPhase2Application()
        let host = phase2Host()
        try await coordinator.save(host)
        let gate = Phase7LocalNetworkPermissionGateFake(status: .denied)
        let preferences = Phase7PreferencesStore()
        let harness = Phase7RootViewHarness(
            rootView: RootView(
                coordinator: coordinator,
                preferencesStore: preferences,
                localNetworkPermissionGate: gate
            )
        )
        defer { harness.close() }

        let surfaceLoaded = await harness.waitUntil {
            harness.view(with: "local-network-permission-onboarding") != nil
                || harness.view(
                    with: "host-connect-\(host.id.uuidString)"
                ) != nil
        }
        XCTAssertTrue(surfaceLoaded)
        XCTAssertNotNil(
            harness.view(with: "local-network-permission-onboarding"),
            "The first launch should explain local-network access before showing Hosts"
        )
        XCTAssertNil(
            harness.view(with: "host-connect-\(host.id.uuidString)"),
            "Hosts must remain gated until local-network onboarding is completed"
        )
    }

    func testGrantingLocalNetworkPermissionShowsHostsAndPersistsAcrossLaunches() async throws {
        let coordinator = makeMissingPhase2Application()
        let host = phase2Host()
        try await coordinator.save(host)
        let preferences = Phase7PreferencesStore()
        let firstGate = Phase7LocalNetworkPermissionGateFake(
            status: .undetermined,
            requestResult: .granted
        )
        let firstLaunch = Phase7RootViewHarness(
            rootView: RootView(
                coordinator: coordinator,
                preferencesStore: preferences,
                localNetworkPermissionGate: firstGate
            )
        )
        defer { firstLaunch.close() }

        let firstSurfaceLoaded = await firstLaunch.waitUntil {
            firstLaunch.view(with: "local-network-permission-onboarding") != nil
        }
        guard firstSurfaceLoaded else {
            XCTFail("The first launch should present local-network onboarding")
            return
        }
        guard firstLaunch.activate(identifier: "local-network-permission-continue") else {
            XCTFail("Onboarding must provide a completion action")
            return
        }

        let hostsShown = await firstLaunch.waitUntil {
            firstLaunch.view(
                with: "host-connect-\(host.id.uuidString)"
            ) != nil
                && firstLaunch.view(
                    with: "local-network-permission-onboarding"
                ) == nil
        }
        XCTAssertTrue(hostsShown)
        let firstRequestCount = await firstGate.requestCount()
        XCTAssertEqual(firstRequestCount, 1)

        firstLaunch.close()
        let secondGate = Phase7LocalNetworkPermissionGateFake(
            status: .undetermined,
            requestResult: .denied
        )
        let secondLaunch = Phase7RootViewHarness(
            rootView: RootView(
                coordinator: coordinator,
                preferencesStore: preferences,
                localNetworkPermissionGate: secondGate
            )
        )
        defer { secondLaunch.close() }

        let persistedAccess = await secondLaunch.waitUntil {
            secondLaunch.view(
                with: "host-connect-\(host.id.uuidString)"
            ) != nil
        }
        XCTAssertTrue(persistedAccess)
        XCTAssertNil(
            secondLaunch.view(with: "local-network-permission-onboarding"),
            "A later launch must not present onboarding after it was completed"
        )
        let secondRequestCount = await secondGate.requestCount()
        XCTAssertEqual(
            secondRequestCount,
            0,
            "Persisted onboarding must not request system permission again"
        )
    }

    func testAlreadyGrantedLocalNetworkPermissionSkipsOnboarding() async throws {
        let coordinator = makeMissingPhase2Application()
        let host = phase2Host()
        try await coordinator.save(host)
        let gate = Phase7LocalNetworkPermissionGateFake(status: .granted)
        let harness = Phase7RootViewHarness(
            rootView: RootView(
                coordinator: coordinator,
                preferencesStore: Phase7PreferencesStore(),
                localNetworkPermissionGate: gate
            )
        )
        defer { harness.close() }

        let hostsShown = await harness.waitUntil {
            harness.view(with: "host-connect-\(host.id.uuidString)") != nil
        }
        XCTAssertTrue(hostsShown)
        XCTAssertNil(harness.view(with: "local-network-permission-onboarding"))
        let statusReadCount = await gate.statusReadCount()
        XCTAssertGreaterThanOrEqual(
            statusReadCount,
            1,
            "The granted path must consult local-network permission state"
        )
        let requestCount = await gate.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testShortcutBarRemainsVisibleAfterKeyboardDismissal() async {
        let terminalView = ShellTerminalView(frame: .zero)
        let windowHarness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            windowHarness.close()
            terminalView.stop()
        }

        _ = terminalView.becomeFirstResponder()
        _ = terminalView.resignFirstResponder()
        try? await Task.sleep(for: .milliseconds(50))

        guard let shortcutBar = terminalView.shortcutBar else {
            XCTFail("The terminal must own a shortcut bar")
            return
        }
        XCTAssertTrue(
            shortcutBar.isDescendant(of: windowHarness.window),
            "The shortcut bar must remain in the terminal hierarchy after keyboard dismissal"
        )
        XCTAssertFalse(shortcutBar.isHidden)
    }

    func testHostListSwipeActionsExposeEditAndDelete() {
        let host = phase2Host()
        var editedHost: Host?
        var deletedHost: Host?
        let actions = HostListActionPolicy.current.swipeActionDescriptors(
            for: host,
            onEdit: { editedHost = $0 },
            onDelete: { deletedHost = $0 }
        )

        XCTAssertEqual(actions.map(\.action), [.edit, .delete])
        guard let editAction = actions.first(where: { $0.action == .edit }),
              let deleteAction = actions.first(where: { $0.action == .delete })
        else {
            XCTFail("Host swipe actions must expose both Edit and Delete")
            return
        }
        XCTAssertEqual(editAction.title, "Edit")
        XCTAssertEqual(editAction.systemImage, "pencil")
        XCTAssertEqual(deleteAction.title, "Delete")
        XCTAssertEqual(deleteAction.systemImage, "trash")

        editAction.perform()
        deleteAction.perform()
        XCTAssertEqual(editedHost, host)
        XCTAssertEqual(deletedHost, host)
    }

    func testShortcutBarIsOnePageWithExactlyTheContractItemsInOrder() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        defer { terminalView.stop() }
        let bar = try XCTUnwrap(terminalView.shortcutBar)

        let expectedIdentifiers = [
            "terminal-shortcut-escape",
            "terminal-shortcut-tab",
            "terminal-shortcut-control",
            "terminal-shortcut-dpad",
            "terminal-shortcut-paste",
            "terminal-shortcut-jump-to",
            "terminal-shortcut-dismiss-keyboard",
        ]
        let actualIdentifiers = phase7ShortcutButtons(in: bar).compactMap {
            $0.accessibilityIdentifier
        }

        XCTAssertEqual(
            actualIdentifiers,
            expectedIdentifiers,
            "The shortcut bar must be a single ordered seven-item model"
        )
        XCTAssertEqual(bar.intrinsicContentSize.height, 44)

        let allIdentifiers = Set(
            phase7Buttons(in: bar).compactMap(\.accessibilityIdentifier)
        )
        for removedIdentifier in [
            "terminal-shortcut-alt",
            "terminal-shortcut-copy",
            "terminal-shortcut-select-all",
            "terminal-shortcut-mouse",
            "terminal-shortcut-page-up",
            "terminal-shortcut-page-down",
        ] {
            XCTAssertFalse(
                allIdentifiers.contains(removedIdentifier),
                "The obsolete \(removedIdentifier) control must not return"
            )
        }
    }

    func testDirectionButtonTogglesFloatingDPadAndSendsTerminalSequences() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let windowHarness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            windowHarness.close()
            terminalView.stop()
        }
        let recorder = Phase7TerminalInputRecorder()
        terminalView.terminalDelegate = recorder
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        let directionButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-dpad", in: bar) as? UIButton
        )

        if let initialOverlay = phase7View(
            with: "terminal-dpad-overlay",
            near: terminalView
        ) {
            XCTAssertTrue(initialOverlay.isHidden)
        }

        directionButton.sendActions(for: .touchUpInside)
        let overlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", near: terminalView)
        )
        XCTAssertFalse(overlay.isHidden)

        let expectedSequences: [(String, [UInt8])] = [
            ("terminal-dpad-up", EscapeSequences.moveUpNormal),
            ("terminal-dpad-down", EscapeSequences.moveDownNormal),
            ("terminal-dpad-left", EscapeSequences.moveLeftNormal),
            ("terminal-dpad-right", EscapeSequences.moveRightNormal),
            ("terminal-dpad-enter", EscapeSequences.cmdRet),
            ("terminal-dpad-page-up", EscapeSequences.cmdPageUp),
            ("terminal-dpad-page-down", EscapeSequences.cmdPageDown),
        ]

        for (identifier, expectedBytes) in expectedSequences {
            let visibleOverlay = try XCTUnwrap(
                phase7View(with: "terminal-dpad-overlay", near: terminalView)
            )
            if visibleOverlay.isHidden {
                directionButton.sendActions(for: .touchUpInside)
            }
            let button = try XCTUnwrap(
                phase7View(with: identifier, near: terminalView) as? UIButton,
                "The floating D-pad is missing \(identifier)"
            )
            let inputCount = recorder.sentBytes.count
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(
                recorder.sentBytes.count,
                inputCount + 1,
                "\(identifier) must use the terminal input path"
            )
            XCTAssertEqual(
                recorder.sentBytes.last,
                expectedBytes,
                "\(identifier) sent the wrong terminal sequence"
            )
        }

        directionButton.sendActions(for: .touchUpInside)
        let hiddenOverlay = try XCTUnwrap(
            phase7View(with: "terminal-dpad-overlay", near: terminalView)
        )
        XCTAssertTrue(hiddenOverlay.isHidden)
    }

    func testJumpToUsesPanePickerCallbackWithoutToolbarEntry() async throws {
        let channel = Phase4OutputChannel()
        let session = SSHShellSession(connectedChannel: channel)
        let host = phase2Host()
        var openPanePickerCalls = 0
        let harness = Phase7TerminalScreenHarness(
            host: host,
            session: session,
            onDisconnect: {},
            onBackToBrowser: {},
            onOpenPanePicker: { openPanePickerCalls += 1 }
        )
        defer { harness.close() }

        let terminalView = await harness.terminal()
        let terminal = try XCTUnwrap(terminalView)
        let controller = harness.controller
        let bar = try XCTUnwrap(terminal.shortcutBar)
        XCTAssertNil(
            phase7View(with: "open-pane-picker", in: controller.view),
            "Pane Picker must be entered from Jump To, not the top toolbar"
        )

        let jumpButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-jump-to", in: bar) as? UIButton
        )
        XCTAssertEqual(jumpButton.title(for: .normal), "Jump To")
        XCTAssertTrue(phase7Activate(jumpButton))
        XCTAssertEqual(
            openPanePickerCalls,
            1,
            "Jump To must invoke the existing open-pane-picker callback"
        )
    }

    func testRootTerminalToolbarBackToHostsUsesReturnToHostsSemantics() async throws {
        let fixture = try Phase3HerdrFixtures.single()
        let pane = try XCTUnwrap(phase4Panes(in: fixture).first)
        let host = phase2Host()
        let application = makePhase4NavigationApplication(fixture: fixture)
        try await application.save(host)

        let harness = Phase7RootViewHarness(
            rootView: RootView(model: application.model)
        )
        defer {
            application.model.disconnect()
            harness.close()
        }

        application.model.connect(to: host)
        let connected = await harness.waitUntil {
            application.model.activeConnection != nil
                && application.model.herdrState != nil
        }
        XCTAssertTrue(connected)
        guard connected else { return }

        application.model.selectPane(pane.id)
        let attached = await harness.waitUntil {
            if case .attached = application.model.herdrState {
                return true
            }
            return false
        }
        XCTAssertTrue(attached)
        guard attached else { return }

        let terminalVisible = await harness.waitUntil {
            harness.view(with: "ssh-terminal") != nil
        }
        XCTAssertTrue(terminalVisible)
        guard terminalVisible else { return }

        let backVisible = await harness.waitUntil {
            harness.view(with: "return-to-hosts") != nil
                || harness.view(with: "terminal-back-to-hosts") != nil
        }
        XCTAssertTrue(backVisible)
        guard let backButton = harness.view(with: "return-to-hosts")
            ?? harness.view(with: "terminal-back-to-hosts")
        else {
            XCTFail("The terminal toolbar must expose a Back to Hosts button")
            return
        }

        XCTAssertTrue(phase7Activate(backButton))
        let returnedToHosts = await harness.waitUntil {
            application.model.activeConnection == nil
                && application.model.herdrState == nil
                && application.model.isTearingDown
        }
        XCTAssertTrue(
            returnedToHosts,
            "Back to Hosts must invoke RootViewModel.returnToHosts"
        )
    }

    func testTerminalToolbarDoesNotExposeDisconnectButton() async {
        let session = SSHShellSession(connectedChannel: Phase4OutputChannel())
        let harness = Phase7TerminalScreenHarness(
            host: phase2Host(),
            session: session,
            onDisconnect: {},
            onBackToBrowser: {},
            onOpenPanePicker: {}
        )
        defer { harness.close() }

        _ = await harness.terminal()
        let disconnectButton = phase7Descendants(of: harness.controller.view)
            .first { view in
                let labels = [
                    view.accessibilityLabel,
                    view.accessibilityValue,
                    (view as? UIButton)?.title(for: .normal),
                    (view as? UILabel)?.text,
                ].compactMap { $0 }
                return view.accessibilityIdentifier == "terminal-disconnect"
                    || labels.contains {
                        $0.localizedCaseInsensitiveContains("Disconnect")
                    }
            }
        XCTAssertNil(
            disconnectButton,
            "The terminal toolbar must not expose a redundant Disconnect item"
        )
    }

    func testControlLatchShowsCombosSendsControlBytesAndClears() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let windowHarness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            windowHarness.close()
            terminalView.stop()
        }
        let recorder = Phase7TerminalInputRecorder()
        terminalView.terminalDelegate = recorder
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        let controlButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-control", in: bar) as? UIButton
        )

        if let popup = phase7View(
            with: "terminal-control-combo-popup",
            near: terminalView
        ) {
            XCTAssertTrue(popup.isHidden)
        }

        controlButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(controlButton.isSelected)
        let popup = try XCTUnwrap(
            phase7View(with: "terminal-control-combo-popup", near: terminalView)
        )
        XCTAssertFalse(popup.isHidden)

        let expectedControlBytes: [(String, UInt8)] = [
            ("C", 0x03),
            ("D", 0x04),
            ("L", 0x0c),
            ("A", 0x01),
            ("E", 0x05),
            ("U", 0x15),
            ("K", 0x0b),
            ("W", 0x17),
        ]

        for (index, (label, expectedByte)) in expectedControlBytes.enumerated() {
            if index > 0 {
                if !controlButton.isSelected {
                    controlButton.sendActions(for: .touchUpInside)
                }
                let visiblePopup = try XCTUnwrap(
                    phase7View(
                        with: "terminal-control-combo-popup",
                        near: terminalView
                    )
                )
                XCTAssertFalse(visiblePopup.isHidden)
            }

            let activePopup = try XCTUnwrap(
                phase7View(
                    with: "terminal-control-combo-popup",
                    near: terminalView
                )
            )
            let comboButton = try XCTUnwrap(
                phase7Buttons(in: activePopup).first {
                    $0.title(for: .normal) == label
                        || $0.accessibilityLabel == label
                },
                "The Ctrl popup is missing the \(label) combo"
            )
            let inputCount = recorder.sentBytes.count
            comboButton.sendActions(for: .touchUpInside)
            XCTAssertEqual(recorder.sentBytes.count, inputCount + 1)
            XCTAssertEqual(recorder.sentBytes.last, [expectedByte])
            XCTAssertFalse(controlButton.isSelected)
            let hiddenPopup = phase7View(
                with: "terminal-control-combo-popup",
                near: terminalView
            )
            XCTAssertTrue(hiddenPopup == nil || hiddenPopup?.isHidden == true)
        }
    }

    func testKeyboardInputStillUsesLatchedControlModifierWithoutPopup() throws {
        let terminalView = ShellTerminalView(frame: .zero)
        let windowHarness = Phase7TerminalViewHarness(terminalView: terminalView)
        defer {
            windowHarness.close()
            terminalView.stop()
        }
        let recorder = Phase7TerminalInputRecorder()
        terminalView.terminalDelegate = recorder
        let bar = try XCTUnwrap(terminalView.shortcutBar)
        let controlButton = try XCTUnwrap(
            phase7View(with: "terminal-shortcut-control", in: bar) as? UIButton
        )

        let initialPopup = phase7View(
            with: "terminal-control-combo-popup",
            near: terminalView
        )
        XCTAssertTrue(
            initialPopup == nil || initialPopup?.isHidden == true,
            "The Ctrl popup must not be visible before Ctrl is latched"
        )
        controlButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(terminalView.controlModifier)

        terminalView.insertText("c")

        XCTAssertEqual(recorder.sentBytes.last, [0x03])
        XCTAssertFalse(terminalView.controlModifier)
    }
}
