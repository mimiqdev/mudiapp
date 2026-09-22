import Foundation
import HerdrKit
import SwiftUI
import UIKit
import XCTest
@testable import Mudi

/// Phase 10 picker polish: the pane the user is currently viewing is marked
/// in the picker by its real Herdr pane identity, not by its list position,
/// and the mark survives refresh and reconnect hydration.
@MainActor
final class Phase10PanePickerHighlightTests: XCTestCase {  // pi-lens-ignore: type_body_length
    func testCurrentPaneHighlightFollowsPaneIdentityWhenRefreshReordersAndRelocatesIt() async throws {
        let initial = phase10Snapshot([
            (id: "w1", panes: [
                phase10Pane("w1:p1"),
                phase10Pane("w1:p2"),
                phase10Pane("w1:p3"),
            ]),
        ])
        let later = phase10Snapshot([
            (id: "w1", panes: [phase10Pane("w1:p3"), phase10Pane("w1:p1")]),
            (id: "w2", panes: [phase10Pane("w1:p2")]),
        ])
        let application = makeMissingPhase6Application(
            snapshots: [initial, later]
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        _ = await application.selectPane("w1:p2")

        let pickerState = await application.openPicker(from: .terminal)
        guard case let .panePicker(picker) = pickerState else {
            XCTFail("A terminal-origin picker should stay presented")
            return
        }
        XCTAssertEqual(picker.currentPaneID, "w1:p2")
        XCTAssertTrue(picker.highlight(for: "w1:p2").isCurrent)
        XCTAssertFalse(picker.highlight(for: "w1:p1").isCurrent)
        XCTAssertFalse(picker.highlight(for: "w1:p3").isCurrent)

        let refreshedState = await application.refreshPicker()
        guard case let .panePicker(refreshed) = refreshedState else {
            XCTFail("Refreshing a visible picker should keep it presented")
            return
        }
        XCTAssertEqual(refreshed.snapshot, later)

        let rows = panePickerPresentationSections(in: later).flatMap(\.rows)
        XCTAssertEqual(
            rows.map(\.paneID),
            ["w1:p3", "w1:p1", "w1:p2"],
            "The later snapshot must relocate the attached pane to the last row"
        )
        XCTAssertEqual(
            refreshed.currentPaneID,
            "w1:p2",
            "Refresh must keep the real pane identity, not the previous row"
        )
        XCTAssertEqual(
            rows.filter { refreshed.highlight(for: $0.paneID).isCurrent }
                .map(\.paneID),
            ["w1:p2"],
            "Only the attached pane row is marked after the refresh"
        )
    }

    func testCurrentPaneHighlightSurvivesReconnectHydrationOfTheSamePaneIdentity() async throws {
        let initial = phase10Snapshot([
            (id: "w1", panes: [
                phase10Pane("w1:p1", title: "before reconnect", terminalID: "term-A"),
                phase10Pane("w1:p2"),
            ]),
        ])
        let reconnectedPane = phase10Pane(
            "w1:p1",
            title: "after reconnect",
            terminalID: "term-reconnected"
        )
        let hydrated = phase10Snapshot([
            (id: "w2", panes: [phase10Pane("w1:p2"), reconnectedPane]),
        ])
        let application = makeMissingPhase6Application(
            snapshots: [initial, hydrated]
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        _ = await application.selectPane("w1:p1")
        _ = await application.openPicker(from: .terminal)

        let refreshedState = await application.refreshPicker()
        guard case let .panePicker(refreshed) = refreshedState else {
            XCTFail("Refreshing a visible picker should keep it presented")
            return
        }
        XCTAssertEqual(refreshed.snapshot, hydrated)
        XCTAssertEqual(refreshed.currentPaneID, "w1:p1")
        XCTAssertEqual(
            refreshed.attachedTerminal?.pane.terminalID,
            "term-reconnected",
            "Refresh must rehydrate the attached pane value from the fresh snapshot"
        )

        // The transparent-reconnect path re-syncs the terminal context from
        // the fresh snapshot and re-opens the picker without dismissing it.
        let session = try XCTUnwrap(hydrated.sessions.first)
        await application.synchronizeTerminalContext(
            .attached(
                PanePickerAttachedTerminal(
                    host: host,
                    session: session,
                    pane: reconnectedPane
                )
            )
        )
        let reopenedState = await application.openPicker(from: .terminal)
        guard case let .panePicker(reopened) = reopenedState else {
            XCTFail("A hydrated terminal context should keep the picker presented")
            return
        }
        XCTAssertEqual(reopened.currentPaneID, "w1:p1")
        XCTAssertEqual(
            panePickerPresentationSections(in: hydrated)
                .flatMap(\.rows)
                .filter { reopened.highlight(for: $0.paneID).isCurrent }
                .map(\.paneID),
            ["w1:p1"],
            "Reconnect hydration must not move the mark to the first row"
        )
    }

    func testCurrentPaneHighlightMovesToTheNewlyAttachedPaneAfterSwitching() async throws {
        let snapshot = phase10Snapshot([
            (id: "w1", panes: [
                phase10Pane("w1:p1"),
                phase10Pane("w1:p2"),
                phase10Pane("w1:p3"),
            ]),
        ])
        let application = makeMissingPhase6Application(snapshots: [snapshot])
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        _ = await application.selectPane("w1:p1")

        let firstPicker = await application.openPicker(from: .terminal)
        guard case let .panePicker(first) = firstPicker else {
            XCTFail("The first terminal-origin picker should be presented")
            return
        }
        XCTAssertEqual(first.currentPaneID, "w1:p1")

        _ = await application.selectPane("w1:p3")
        let switchedPicker = await application.openPicker(from: .terminal)
        guard case let .panePicker(switched) = switchedPicker else {
            XCTFail("The picker after switching should be presented")
            return
        }
        XCTAssertEqual(
            switched.currentPaneID,
            "w1:p3",
            "The mark must follow the pane that is actually attached now"
        )
        XCTAssertTrue(switched.highlight(for: "w1:p3").isCurrent)
        XCTAssertFalse(switched.highlight(for: "w1:p1").isCurrent)
    }

    func testHostOriginPickerMarksNoRowAsCurrent() async throws {
        let snapshot = phase10Snapshot([
            (id: "w1", panes: [phase10Pane("w1:p1"), phase10Pane("w1:p2")]),
        ])
        let application = makeMissingPhase6Application(snapshots: [snapshot])
        let host = phase6Host()

        _ = try await application.connect(to: host)
        let pickerState = await application.openPicker(from: .host)
        guard case let .panePicker(picker) = pickerState else {
            XCTFail("A Host-origin picker should be presented")
            return
        }
        XCTAssertNil(picker.currentPaneID)
        XCTAssertFalse(picker.highlight(for: "w1:p1").isCurrent)
        XCTAssertFalse(picker.highlight(for: "w1:p2").isCurrent)
    }

    func testTappingTheHighlightedRowReattachesTheSamePaneWithoutReleaseOrTakeover() async throws {
        let snapshot = phase10Snapshot([
            (id: "w1", panes: [
                phase10Pane("w1:p1"),
                phase10Pane("w1:p2"),
                phase10Pane("w1:p3"),
            ]),
        ])
        let recorder = Phase6OperationRecorder()
        let transport = Phase6PaneControlTransport(recorder: recorder)
        let application = makeMissingPhase6Application(
            snapshots: [snapshot],
            recorder: recorder,
            transport: transport
        )
        let host = phase6Host()

        _ = try await application.connect(to: host)
        _ = await application.openPicker(from: .host)
        _ = await application.selectPane("w1:p2")
        _ = await application.openPicker(from: .terminal)

        let operationsBeforeTap = await recorder.operations()
        let tappedState = await application.selectPane("w1:p2")
        guard case let .terminal(.attached(attached)) = tappedState else {
            XCTFail("Tapping the highlighted row should keep the same pane attached")
            return
        }
        XCTAssertEqual(attached.pane.id, "w1:p2")
        XCTAssertEqual(attached.session.id, snapshot.sessions.first?.id)

        let operationsAfterTap = await recorder.operations()
        XCTAssertEqual(
            operationsAfterTap,
            operationsBeforeTap,
            "Re-selecting the current pane must not release or take over control again"
        )
    }

    func testPanePickerRowHighlightMarksOnlyTheCurrentPane() {
        let currentPaneID: Pane.ID = "w1:p2"

        let marked = PanePickerRowHighlight.resolve(
            paneID: "w1:p2",
            currentPaneID: currentPaneID
        )
        XCTAssertTrue(marked.isCurrent)
        XCTAssertEqual(marked.paneID, "w1:p2")
        XCTAssertEqual(marked.accessibilityValue, "Current pane")

        let sibling = PanePickerRowHighlight.resolve(
            paneID: "w1:p1",
            currentPaneID: currentPaneID
        )
        XCTAssertFalse(sibling.isCurrent)
        XCTAssertNil(sibling.accessibilityValue)

        let hostOrigin = PanePickerRowHighlight.resolve(
            paneID: "w1:p1",
            currentPaneID: nil
        )
        XCTAssertFalse(
            hostOrigin.isCurrent,
            "Without a real attached pane identity no row may be marked"
        )
    }

    func testPickerViewMarksAndAnnouncesOnlyTheCurrentPaneRow() async throws {
        let snapshot = phase10Snapshot([
            (id: "w1", panes: [
                phase10Pane("w1:p1"),
                phase10Pane("w1:p2"),
                phase10Pane("w1:p3"),
            ]),
        ])
        let harness = try Phase10PickerHarness(
            state: phase10PickerState(
                snapshot: snapshot,
                attachedPaneID: "w1:p2"
            )
        )
        defer { harness.close() }

        let loaded = await harness.waitUntil {
            harness.element(with: "pane-picker-pane-w1:p2") != nil
                && harness.element(with: "pane-picker-pane-w1:p1") != nil
                && harness.element(with: "pane-picker-pane-w1:p3") != nil
        }
        XCTAssertTrue(loaded)

        let currentRow = try XCTUnwrap(
            harness.element(with: "pane-picker-pane-w1:p2")
        )
        XCTAssertTrue(
            phase10AccessibilityTraits(currentRow).contains(.selected),
            "The current pane row must be announced as selected"
        )
        XCTAssertEqual(
            phase10AccessibilityString(currentRow, "accessibilityValue"),
            "Current pane",
            "The current pane row must be announced as the current pane"
        )

        for otherPaneID in ["w1:p1", "w1:p3"] {
            let otherRow = try XCTUnwrap(
                harness.element(with: "pane-picker-pane-\(otherPaneID)")
            )
            XCTAssertFalse(
                phase10AccessibilityTraits(otherRow).contains(.selected),
                "\(otherPaneID) is not the current pane and must not be selected"
            )
            XCTAssertNotEqual(
                phase10AccessibilityString(otherRow, "accessibilityValue"),
                "Current pane"
            )
        }
    }

    func testPickerViewKeepsTheMarkOnTheRelocatedCurrentPaneAfterReload() async throws {
        let initial = phase10Snapshot([
            (id: "w1", panes: [
                phase10Pane("w1:p1"),
                phase10Pane("w1:p2"),
                phase10Pane("w1:p3"),
            ]),
        ])
        let relocated = phase10Snapshot([
            (id: "w1", panes: [phase10Pane("w1:p3"), phase10Pane("w1:p1")]),
            (id: "w2", panes: [phase10Pane("w1:p2")]),
        ])
        let harness = try Phase10PickerHarness(
            state: phase10PickerState(
                snapshot: initial,
                attachedPaneID: "w1:p2"
            )
        )
        defer { harness.close() }

        let initialLoaded = await harness.waitUntil {
            harness.element(with: "pane-picker-pane-w1:p2") != nil
        }
        XCTAssertTrue(initialLoaded)
        XCTAssertTrue(
            phase10AccessibilityTraits(
                try XCTUnwrap(harness.element(with: "pane-picker-pane-w1:p2"))
            ).contains(.selected)
        )

        harness.render(
            try phase10PickerState(
                snapshot: relocated,
                attachedPaneID: "w1:p2"
            )
        )

        let relocatedMarked = await harness.waitUntil {
            guard let element = harness.element(with: "pane-picker-pane-w1:p2")
            else { return false }
            return phase10AccessibilityTraits(element).contains(.selected)
        }
        XCTAssertTrue(
            relocatedMarked,
            "Reloading the picker must keep the mark on the same pane identity"
        )
        for otherPaneID in ["w1:p1", "w1:p3"] {
            let otherRow = try XCTUnwrap(
                harness.element(with: "pane-picker-pane-\(otherPaneID)")
            )
            XCTAssertFalse(
                phase10AccessibilityTraits(otherRow).contains(.selected),
                "\(otherPaneID) must stay unmarked after the reload"
            )
        }
    }
}

// MARK: - Fixtures

private func phase10Pane(
    _ id: Pane.ID,
    title: String? = nil,
    terminalID: String? = nil
) -> Pane {
    Pane(
        id: id,
        title: title ?? "pane \(id)",
        agent: nil,
        terminalID: terminalID ?? "term-\(id)"
    )
}

private func phase10Snapshot(
    _ workspaces: [(id: Workspace.ID, panes: [Pane])]
) -> HerdrSnapshot {
    HerdrSnapshot(
        sessions: [
            HerdrSession(
                id: "default",
                name: "default",
                isDefault: true,
                workspaces: workspaces.map { entry in
                    Workspace(
                        id: entry.id,
                        name: entry.id,
                        tabs: [
                            Tab(
                                id: "\(entry.id):t1",
                                name: "\(entry.id):t1",
                                panes: entry.panes
                            ),
                        ]
                    )
                }
            ),
        ]
    )
}

private func phase10PickerState(
    snapshot: HerdrSnapshot,
    attachedPaneID: Pane.ID?
) throws -> PanePickerState {
    let host = phase6Host()
    let session = try XCTUnwrap(snapshot.sessions.first)
    let pane = attachedPaneID.flatMap { paneID in
        phase6Panes(in: snapshot).first { $0.id == paneID }
    }
    return PanePickerState(
        host: host,
        origin: .terminal,
        snapshot: snapshot,
        attachedTerminal: pane.map {
            PanePickerAttachedTerminal(
                host: host,
                session: session,
                pane: $0
            )
        }
    )
}

// MARK: - Accessibility element access

/// SwiftUI exposes `List` rows as accessibility proxy objects that are not
/// `UIView`s. The helpers below walk both trees and read the proxies through
/// the Objective-C accessibility selectors they respond to.
@MainActor
private func phase10AccessibilityElement(
    with identifier: String,
    in root: UIView
) -> NSObject? {
    var pending: [NSObject] = [root]
    var visited: Set<ObjectIdentifier> = []
    while let object = pending.popLast() {
        guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
        if phase10AccessibilityString(object, "accessibilityIdentifier") == identifier {
            return object
        }
        guard let view = object as? UIView else { continue }
        pending.append(contentsOf: view.subviews)
        pending.append(
            contentsOf: (view.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        )
    }
    return nil
}

private func phase10AccessibilityString(
    _ object: NSObject,
    _ selectorName: String
) -> String? {
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return nil }
    typealias Getter = @convention(c) (NSObject, Selector) -> Unmanaged<AnyObject>?
    let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
    return getter(object, selector)?.takeUnretainedValue() as? String
}

private func phase10AccessibilityTraits(_ object: NSObject) -> UIAccessibilityTraits {
    let selector = NSSelectorFromString("accessibilityTraits")
    guard object.responds(to: selector) else { return [] }
    typealias Getter = @convention(c) (NSObject, Selector) -> UInt64
    let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
    return UIAccessibilityTraits(rawValue: getter(object, selector))
}

// MARK: - Rendered picker harness

@MainActor
private final class Phase10PickerStateBox: ObservableObject {
    @Published var state: PanePickerState

    init(state: PanePickerState) {
        self.state = state
    }
}

@MainActor
private struct Phase10PickerProbe: View {
    @ObservedObject var box: Phase10PickerStateBox

    var body: some View {
        PanePickerView(
            state: box.state,
            onDismiss: {},
            onRefresh: {},
            onCreateWorkspace: {},
            isCreatingWorkspace: false,
            onSelectPane: { _ in },
            onSelectOrdinaryTerminal: {},
            onAppear: {}
        )
    }
}

@MainActor
private final class Phase10PickerHarness {
    private let window: UIWindow
    private let controller: UIHostingController<Phase10PickerProbe>
    private let box: Phase10PickerStateBox

    init(state: PanePickerState) {
        box = Phase10PickerStateBox(state: state)
        window = Phase7TerminalScreenHarness.makeWindow()
        controller = UIHostingController(
            rootView: Phase10PickerProbe(box: box)
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.loadViewIfNeeded()
        Phase7TerminalScreenHarness.kickAppearance(of: controller)
    }

    func render(_ state: PanePickerState) {
        box.state = state
    }

    /// SwiftUI List rows are exposed as accessibility proxy objects, not
    /// UIViews, so the rendered row must be found through the accessibility
    /// element tree instead of the plain subview tree.
    func element(with identifier: String) -> NSObject? {
        phase10AccessibilityElement(with: identifier, in: controller.view)
    }

    func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func close() {
        controller.view.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }
}
