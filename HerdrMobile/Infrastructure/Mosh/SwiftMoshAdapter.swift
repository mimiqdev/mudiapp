import HerdrKit
import MoshBootstrap
import MoshCore

/// The vertical slice will connect MoshClientSession to TerminalTransport and SwiftTerm.
enum SwiftMoshAdapter {
    static let transportKind = ActiveTransport.mosh
}
