import HerdrKit
@preconcurrency import SwiftTerm
import SwiftUI

struct TerminalViewContainer: UIViewRepresentable {
    let session: SSHShellSession
    let onError: (String) -> Void

    func makeUIView(context: Context) -> ShellTerminalView {
        let terminalView = ShellTerminalView(frame: .zero)
        terminalView.start(session: session, onError: onError)
        return terminalView
    }

    func updateUIView(_ terminalView: ShellTerminalView, context: Context) {
        terminalView.updateSession(session: session, onError: onError)
    }

    static func dismantleUIView(_ terminalView: ShellTerminalView, coordinator: ()) {
        terminalView.stop()
    }
}

@MainActor
final class ShellTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
    private var session: SSHShellSession?
    private var sessionIdentity: ObjectIdentifier?
    private var outputTask: Task<Void, Never>?
    private var onError: ((String) -> Void)?

    private enum TerminalSessionError: Error, Sendable {
        case remoteClosed
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        nativeBackgroundColor = .black
        backgroundColor = .black
        isOpaque = true
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start(session: SSHShellSession, onError: @escaping (String) -> Void) {
        guard outputTask == nil else { return }
        self.session = session
        sessionIdentity = ObjectIdentifier(session)
        self.onError = onError
        terminalDelegate = self
        let sessionIdentity = ObjectIdentifier(session)

        outputTask = Task { [weak self, session, sessionIdentity] in
            let output = await session.outputStream()
            do {
                for try await bytes in output {
                    guard !Task.isCancelled else { return }
                    guard let self,
                          self.sessionIdentity == sessionIdentity
                    else { return }
                    guard !bytes.isEmpty else { continue }
                    self.feed(byteArray: bytes[...])
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionIdentity == sessionIdentity
                else { return }
                await session.disconnect()
                guard !Task.isCancelled,
                      self.sessionIdentity == sessionIdentity
                else { return }
                self.report(error)
                return
            }

            guard !Task.isCancelled,
                  let self,
                  self.sessionIdentity == sessionIdentity
            else { return }
            await session.disconnect()
            guard !Task.isCancelled,
                  self.sessionIdentity == sessionIdentity
            else { return }
            self.report(TerminalSessionError.remoteClosed)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.sessionIdentity == sessionIdentity
            else { return }
            _ = becomeFirstResponder()
            sendCurrentSize()
        }
    }

    func updateSession(
        session: SSHShellSession,
        onError: @escaping (String) -> Void
    ) {
        self.onError = onError
        guard sessionIdentity != ObjectIdentifier(session) else { return }
        stop()
        start(session: session, onError: onError)
    }

    func stop() {
        outputTask?.cancel()
        outputTask = nil
        terminalDelegate = nil
        session = nil
        sessionIdentity = nil
        onError = nil
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        guard !bytes.isEmpty, let session else { return }
        Task {
            do {
                try await session.send(bytes)
            } catch {
                report(error)
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resize(columns: newCols, rows: newRows)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.setValue(content, forPasteboardType: "public.data")
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func sendCurrentSize() {
        let terminal = getTerminal()
        resize(columns: terminal.cols, rows: terminal.rows)
    }

    private func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, let session else { return }
        Task {
            do {
                try await session.resize(columns: columns, rows: rows)
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        let message: String
        if let shellError = error as? SSHShellError, let description = shellError.errorDescription {
            message = description
        } else {
            message = "The SSH shell connection was lost."
        }
        onError?(message)
    }
}
