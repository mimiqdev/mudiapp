import Foundation

public struct Host: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var preferredTransport: TransportPreference

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: UInt16 = 22,
        username: String,
        preferredTransport: TransportPreference = .automatic
    ) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.preferredTransport = preferredTransport
    }
}

public enum TransportPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case mosh
    case ssh
}

public enum ActiveTransport: String, Codable, Sendable {
    case mosh
    case ssh
}
