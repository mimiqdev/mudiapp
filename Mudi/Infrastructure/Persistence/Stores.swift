import Foundation
import HerdrKit
import Security

/// Stores only the Codable, non-secret host configuration in the app support
/// directory. Credentials and host keys use the Keychain stores below.
actor JSONHostStore: HostStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func loadHosts() throws -> [Host] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Host].self, from: data)
    }

    func save(_ host: Host) throws {
        var hosts = try loadHosts()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        try write(hosts)
    }

    func delete(_ host: Host) throws {
        let hosts = try loadHosts().filter { $0.id != host.id }
        try write(hosts)
    }

    private func write(_ hosts: [Host]) throws {
        let data = try JSONEncoder().encode(hosts)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("Mudi", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }
}

/// Errors from the Keychain are deliberately coarse so no secret material is
/// ever included in an error description or log message.
enum KeychainStoreError: Error, LocalizedError, Sendable {
    case operationFailed(status: OSStatus)
    case malformedValue

    var errorDescription: String? {
        switch self {
        case .operationFailed:
            "Unable to access saved SSH credentials."
        case .malformedValue:
            "Saved SSH credentials are invalid."
        }
    }
}

struct KeychainCredentialStore: CredentialStore, Sendable {
    private let store: KeychainDataStore

    init(service: String = "dev.mudi.mobile.credentials") {
        store = KeychainDataStore(service: service)
    }

    func save(_ credentials: SSHCredentials, for host: Host) async throws {
        let value = PersistedCredentials(
            password: credentials.password,
            pemPrivateKey: credentials.pemPrivateKey
        )
        let data = try JSONEncoder().encode(value)
        try store.replace(data, account: host.id.uuidString)
    }

    func credentials(for host: Host) async throws -> SSHCredentials? {
        guard let data = try store.read(account: host.id.uuidString) else {
            return nil
        }
        let value: PersistedCredentials
        do {
            value = try JSONDecoder().decode(PersistedCredentials.self, from: data)
        } catch {
            throw KeychainStoreError.malformedValue
        }
        return SSHCredentials(password: value.password, pemPrivateKey: value.pemPrivateKey)
    }

    func delete(for host: Host) async throws {
        try store.delete(account: host.id.uuidString)
    }
}

struct KeychainKnownHostKeyStore: KnownHostKeyStore, Sendable {
    private let store: KeychainDataStore

    init(service: String = "dev.mudi.mobile.known-host-keys") {
        store = KeychainDataStore(service: service)
    }

    func remember(_ fingerprint: String, for host: Host) async throws {
        try store.replace(
            Data(fingerprint.utf8),
            account: host.id.uuidString
        )
    }

    func fingerprint(for host: Host) async throws -> String? {
        guard let data = try store.read(account: host.id.uuidString) else {
            return nil
        }
        guard let fingerprint = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.malformedValue
        }
        return fingerprint
    }

    func delete(for host: Host) async throws {
        try store.delete(account: host.id.uuidString)
    }
}

private struct PersistedCredentials: Codable {
    let password: String?
    let pemPrivateKey: String?
}

private struct KeychainDataStore: Sendable {
    let service: String

    func replace(_ data: Data, account: String) throws {
        try delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.operationFailed(status: status)
        }
    }

    func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.operationFailed(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.malformedValue
        }
        return data
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(status: status)
        }
    }
}
