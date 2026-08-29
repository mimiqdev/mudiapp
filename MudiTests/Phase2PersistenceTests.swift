import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase2PersistenceTests: XCTestCase {
    func testSavingThenLoadingRestoresHostListAndEncodedHostHasNoSecrets() async throws {
        let hostFile = Phase2HostFile()
        let application = makeMissingPhase2Application(hostFile: hostFile)
        let host = phase2Host()

        try await application.save(host)

        let persistedData = await hostFile.data()
        XCTAssertNotNil(persistedData)

        let loadedHosts = try await application.loadHosts()
        XCTAssertEqual(loadedHosts, [host])

        if let persistedData {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: persistedData) as? [[String: Any]]
            )
            let fields = try XCTUnwrap(object.first?.keys)
            let secretFields = ["password", "pem", "pemPrivateKey", "privateKey"]
            XCTAssertTrue(secretFields.allSatisfy { !fields.contains($0) })
        }
    }

    func testDeletingHostRemovesItFromListKeychainAndRememberedFingerprint() async throws {
        let hostFile = Phase2HostFile()
        let keychain = Phase2Keychain()
        let knownHostKeys = Phase2KnownHostKeys()
        let application = makeMissingPhase2Application(
            hostFile: hostFile,
            keychain: keychain,
            knownHostKeys: knownHostKeys
        )
        let host = phase2Host()
        let credentials = phase2Credentials()
        let fingerprint = "SHA256:remembered-host-key"

        try await hostFile.write(hosts: [host])
        await keychain.put(credentials, for: host)
        await knownHostKeys.remember(fingerprint, for: host)

        let hostsBeforeDelete = try await application.loadHosts()
        XCTAssertEqual(hostsBeforeDelete, [host])

        try await application.delete(host)

        let hostsAfterDelete = try await application.loadHosts()
        XCTAssertFalse(hostsAfterDelete.contains(host))
        let fileHostsAfterDelete = try await hostFile.hosts()
        XCTAssertFalse(fileHostsAfterDelete.contains(host))
        let remainingCredentials = await keychain.credentials(for: host)
        XCTAssertNil(remainingCredentials)
        let applicationCredentials = try await application.credentials(for: host)
        XCTAssertNil(applicationCredentials)
        let remainingFingerprint = await knownHostKeys.fingerprint(for: host)
        XCTAssertNil(remainingFingerprint)
    }

    func testCredentialsAreOnlyAvailableFromKeychainAndNeverHostFileOrUserDefaults() async throws {
        let hostFile = Phase2HostFile()
        let keychain = Phase2Keychain()
        let application = makeMissingPhase2Application(
            hostFile: hostFile,
            keychain: keychain
        )
        let host = phase2Host()
        let credentials = phase2Credentials()
        let markers = [credentials.password, credentials.pemPrivateKey].compactMap { $0 }

        try await application.save(host)
        try await application.save(credentials, for: host)

        let storedCredentials = await keychain.credentials(for: host)
        XCTAssertEqual(storedCredentials, credentials)
        let loadedCredentials = try await application.credentials(for: host)
        XCTAssertEqual(loadedCredentials, credentials)
        let persistedData = await hostFile.data()
        XCTAssertNotNil(persistedData)
        XCTAssertFalse(dataContainsAny(persistedData, markers: markers))
        let defaultsContainsSecret = UserDefaults.standard.dictionaryRepresentation().values.contains {
            valueContainsAny($0, markers: markers)
        }
        XCTAssertFalse(defaultsContainsSecret)
    }

    private func valueContainsAny(_ value: Any, markers: [String]) -> Bool {
        if let string = value as? String {
            return markers.contains(where: string.contains)
        }
        if let data = value as? Data {
            return dataContainsAny(data, markers: markers)
        }
        if let values = value as? [Any] {
            return values.contains { valueContainsAny($0, markers: markers) }
        }
        if let values = value as? [String: Any] {
            return values.values.contains { valueContainsAny($0, markers: markers) }
        }
        return false
    }
}
