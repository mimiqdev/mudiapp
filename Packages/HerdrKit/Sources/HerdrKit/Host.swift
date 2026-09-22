import Foundation

/// One ordered network endpoint for a saved Host. The Host's default port is
/// used when `portOverride` is nil; the endpoint itself never owns credentials
/// or host-key trust.
public struct HostAddress: Identifiable, Codable, Hashable, Sendable {
    public var address: String
    public var portOverride: UInt16?
    private var labelValue: String?

    /// An optional display-only name such as "Home LAN" or "Tailscale".
    /// It is deliberately excluded from endpoint identity and hashing.
    public var label: String? {
        get { labelValue }
        set { labelValue = Self.normalizedLabel(newValue) }
    }

    /// A stable value-derived identity keeps SwiftUI reordering/editing from
    /// requiring another persistence field. Duplicate endpoints are rejected
    /// by the Host persistence boundary. The display label is not part of it.
    public var id: String {
        "\(address)\u{0}\(portOverride.map(String.init) ?? "")"
    }

    public init(
        address: String,
        portOverride: UInt16? = nil,
        label: String? = nil
    ) {
        self.address = address
        self.portOverride = portOverride
        labelValue = Self.normalizedLabel(label)
    }

    public func effectivePort(defaultPort: UInt16) -> UInt16 {
        portOverride ?? defaultPort
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case portOverride
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        portOverride = try container.decodeIfPresent(UInt16.self, forKey: .portOverride)
        labelValue = Self.normalizedLabel(
            try container.decodeIfPresent(String.self, forKey: .label)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        try container.encodeIfPresent(portOverride, forKey: .portOverride)
        try container.encodeIfPresent(label, forKey: .label)
    }

    /// Labels are presentation metadata. Endpoint equality remains stable if
    /// a user renames an address after it was selected or remembered.
    public static func == (lhs: HostAddress, rhs: HostAddress) -> Bool {
        lhs.address == rhs.address && lhs.portOverride == rhs.portOverride
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(address)
        hasher.combine(portOverride)
    }
}

public enum HostAddressValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyAddressList
    case emptyAddress
    case duplicateAddress
    case invalidPort
    case invalidDefaultPort

    public var errorDescription: String? {
        switch self {
        case .emptyAddressList:
            "A host must have at least one address."
        case .emptyAddress:
            "A host address cannot be empty."
        case .duplicateAddress:
            "A host cannot contain duplicate addresses."
        case .invalidPort:
            "A host address port must be between 1 and 65535."
        case .invalidDefaultPort:
            "A host default port must be between 1 and 65535."
        }
    }
}

public struct Host: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var addresses: [HostAddress]
    /// The shared fallback port used by endpoints without an override.
    public var port: UInt16
    public var username: String
    public var preferredTransport: TransportPreference

    /// The selected endpoint is connection-scoped and deliberately omitted
    /// from Codable. It lets every downstream SSH/Mosh/Herdr boundary receive
    /// the actual winner without changing the saved address order.
    private var selectedAddress: HostAddress?

    /// Source compatibility for the single-address model. It reads the
    /// connection-selected address when this Host is an active target and the
    /// first saved address otherwise.
    public var hostname: String {
        get { (selectedAddress ?? addresses.first)?.address ?? "" }
        set {
            let selected = selectedAddress ?? addresses.first
            let replacement = HostAddress(
                address: newValue,
                portOverride: selected?.portOverride,
                label: selected?.label
            )
            if addresses.isEmpty {
                addresses = [replacement]
            } else {
                addresses[0] = replacement
            }
            selectedAddress = nil
        }
    }

    /// The port used by an actual connection. It is the endpoint override or
    /// the Host's shared default port.
    public var effectivePort: UInt16 {
        (selectedAddress ?? addresses.first)?.effectivePort(defaultPort: port) ?? port
    }

    public var effectiveHostname: String { hostname }

    public init(
        id: UUID = UUID(),
        displayName: String,
        hostname: String,
        port: UInt16 = 22,
        username: String,
        preferredTransport: TransportPreference = .automatic
    ) {
        self.init(
            id: id,
            displayName: displayName,
            addresses: [HostAddress(address: hostname)],
            port: port,
            username: username,
            preferredTransport: preferredTransport
        )
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        addresses: [HostAddress],
        port: UInt16 = 22,
        username: String,
        preferredTransport: TransportPreference = .automatic
    ) {
        self.id = id
        self.displayName = displayName
        self.addresses = addresses
        self.port = port
        self.username = username
        self.preferredTransport = preferredTransport
        selectedAddress = nil
    }

    /// Returns a transient connection target. The returned value keeps the
    /// stable Host ID and every saved endpoint while making the selected
    /// address/port visible to adapters that still accept Host.
    public func targeting(_ address: HostAddress) -> Host {
        var target = self
        target.selectedAddress = address
        return target
    }

    public var selectedTarget: HostAddress? { selectedAddress }

    /// The persistence boundary calls this before encoding. Keeping the
    /// validation here makes every store and migration apply the same rules.
    public func validate() throws {
        guard !addresses.isEmpty else {
            throw HostAddressValidationError.emptyAddressList
        }
        guard port > 0 else {
            throw HostAddressValidationError.invalidDefaultPort
        }
        var seen = Set<String>()
        for endpoint in addresses {
            guard !endpoint.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HostAddressValidationError.emptyAddress
            }
            guard endpoint.portOverride.map({ $0 > 0 }) ?? true else {
                throw HostAddressValidationError.invalidPort
            }
            guard seen.insert(endpoint.id).inserted else {
                throw HostAddressValidationError.duplicateAddress
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case addresses
        case hostname
        case port
        case username
        case preferredTransport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decode(String.self, forKey: .displayName)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        preferredTransport = try container.decodeIfPresent(
            TransportPreference.self,
            forKey: .preferredTransport
        ) ?? .automatic

        if let decodedAddresses = try container.decodeIfPresent(
            [HostAddress].self,
            forKey: .addresses
        ) {
            addresses = decodedAddresses
        } else if let legacyHostname = try container.decodeIfPresent(
            String.self,
            forKey: .hostname
        ) {
            addresses = [HostAddress(address: legacyHostname)]
        } else {
            throw HostAddressValidationError.emptyAddressList
        }
        selectedAddress = nil
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(addresses, forKey: .addresses)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(preferredTransport, forKey: .preferredTransport)
    }

    public static func == (lhs: Host, rhs: Host) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.addresses == rhs.addresses
            && lhs.port == rhs.port
            && lhs.username == rhs.username
            && lhs.preferredTransport == rhs.preferredTransport
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(displayName)
        hasher.combine(addresses)
        hasher.combine(port)
        hasher.combine(username)
        hasher.combine(preferredTransport)
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
