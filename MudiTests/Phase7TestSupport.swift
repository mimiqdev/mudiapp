import Foundation
import HerdrKit
import SwiftUI
import UIKit
@preconcurrency import SwiftTerm
@testable import Mudi

actor Phase7LocalNetworkPermissionGateFake: LocalNetworkPermissionGate {
    private var currentStatus: LocalNetworkPermissionStatus
    private let requestedStatus: LocalNetworkPermissionStatus
    private var statusReadCountValue = 0
    private var requestCountValue = 0

    init(
        status: LocalNetworkPermissionStatus,
        requestResult: LocalNetworkPermissionStatus = .granted
    ) {
        currentStatus = status
        requestedStatus = requestResult
    }

    func status() async -> LocalNetworkPermissionStatus {
        statusReadCountValue += 1
        return currentStatus
    }

    func statusReadCount() -> Int {
        statusReadCountValue
    }

    func requestPermission() async -> LocalNetworkPermissionStatus {
        requestCountValue += 1
        currentStatus = requestedStatus
        return currentStatus
    }

    func requestCount() -> Int {
        requestCountValue
    }
}

actor Phase7PreferencesStore: PreferencesStore {
    private var value = TerminalPreferences()

    func load() async throws -> TerminalPreferences {
        value
    }

    func save(_ preferences: TerminalPreferences) async throws {
        value = preferences
    }
}

@MainActor
final class Phase7TerminalInputRecorder: NSObject, @preconcurrency TerminalViewDelegate {
    private(set) var sentBytes: [[UInt8]] = []

    func sizeChanged(source _: TerminalView, newCols _: Int, newRows _: Int) {}

    func setTerminalTitle(source _: TerminalView, title _: String) {}

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        sentBytes.append(Array(data))
    }

    func scrolled(source _: TerminalView, position _: Double) {}

    func requestOpenLink(
        source _: TerminalView,
        link _: String,
        params _: [String: String]
    ) {}

    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
}

@MainActor
final class Phase7TerminalViewHarness {
    let window: UIWindow
    let controller: UIViewController
    let terminalView: ShellTerminalView

    init(
        terminalView: ShellTerminalView,
        chromeView: TerminalChromeView? = nil
    ) {
        self.terminalView = terminalView
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller = UIViewController()
        controller.view.frame = window.bounds
        // Production hosts the terminal inside the chrome (which reserves
        // the shortcut-bar strip); the plain path keeps legacy hosting.
        let host: UIView
        if let chromeView {
            host = chromeView
        } else {
            host = terminalView
        }
        host.frame = controller.view.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(host)
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    func close() {
        terminalView.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }
}

@MainActor
final class Phase7TerminalScreenHarness {
    let window: UIWindow
    let controller: UIHostingController<AnyView>

    init(
        host: Host,
        session: SSHShellSession,
        onDisconnect: @escaping () -> Void,
        onBackToBrowser: (() -> Void)? = nil,
        onOpenPanePicker: (() -> Void)? = nil,
        settingsModel: RootViewModel? = nil
    ) {
        window = Self.makeWindow()
        controller = UIHostingController(
            rootView: AnyView(
                NavigationStack {
                    TerminalScreen(
                        host: host,
                        session: session,
                        transport: .ssh,
                        onDisconnect: onDisconnect,
                        onBackToBrowser: onBackToBrowser,
                        onOpenPanePicker: onOpenPanePicker,
                        onSessionClosed: { _ in },
                        settingsModel: settingsModel
                    )
                }
            )
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.loadViewIfNeeded()
        Self.kickAppearance(of: controller)
    }

    /// iOS 26+ no longer mounts SwiftUI content in manually constructed
    /// windows unless the window is attached to the foreground scene and the
    /// root controller's appearance transition runs explicitly.
    static func makeWindow() -> UIWindow {
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            return UIWindow(windowScene: scene)
        }
        return UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    }

    static func kickAppearance(of controller: UIViewController) {
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
    }

    func terminal() async -> ShellTerminalView? {
        for _ in 0..<200 {
            if let terminal = phase7Descendants(of: controller.view)
                .compactMap({ $0 as? ShellTerminalView })
                .first
            {
                return terminal
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return phase7Descendants(of: controller.view)
            .compactMap { $0 as? ShellTerminalView }
            .first
    }

    func close() {
        phase7Descendants(of: controller.view)
            .compactMap { $0 as? ShellTerminalView }
            .forEach { $0.stop() }
        window.rootViewController = nil
        window.isHidden = true
    }
}

@MainActor
final class Phase7RootViewHarness {
    let window: UIWindow
    let controller: UIHostingController<RootView>

    init(rootView: RootView) {
        window = Phase7TerminalScreenHarness.makeWindow()
        controller = UIHostingController(rootView: rootView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.loadViewIfNeeded()
        Phase7TerminalScreenHarness.kickAppearance(of: controller)
    }

    func close() {
        phase7Descendants(of: controller.view)
            .compactMap { $0 as? ShellTerminalView }
            .forEach { $0.stop() }
        controller.view.removeFromSuperview()
        window.rootViewController = nil
        window.isHidden = true
    }

    func view(with identifier: String) -> UIView? {
        phase7View(with: identifier, in: controller.view)
    }

    func activate(identifier: String) -> Bool {
        guard let view = view(with: identifier) else { return false }
        return phase7Activate(view)
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
}

@MainActor
func phase7Activate(_ view: UIView) -> Bool {
    if let control = view as? UIControl {
        control.sendActions(for: .touchUpInside)
        return true
    }

    var ancestor = view.superview
    while let candidate = ancestor {
        if let control = candidate as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }
        ancestor = candidate.superview
    }

    return view.accessibilityActivate()
}

@MainActor
func phase7View(with identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier {
        return root
    }
    for subview in root.subviews {
        if let match = phase7View(with: identifier, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
func phase7View(with identifier: String, near terminal: UIView) -> UIView? {
    if let match = phase7View(with: identifier, in: terminal) {
        return match
    }
    guard let window = terminal.window else { return nil }
    return phase7View(with: identifier, in: window)
}

@MainActor
func phase7Descendants(of root: UIView) -> [UIView] {
    [root] + root.subviews.flatMap { phase7Descendants(of: $0) }
}

@MainActor
func phase7Buttons(in root: UIView) -> [UIButton] {
    phase7Descendants(of: root).compactMap { $0 as? UIButton }
}

@MainActor
func phase7ShortcutButtons(in bar: MudiTerminalShortcutBar) -> [UIButton] {
    guard let stack = phase7Descendants(of: bar)
        .compactMap({ $0 as? UIStackView })
        .first
    else {
        return []
    }

    let stackedButtons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
    let dismissButton = phase7View(
        with: "terminal-shortcut-dismiss-keyboard",
        in: bar
    ) as? UIButton
    return stackedButtons + (dismissButton.map { [$0] } ?? [])
}
