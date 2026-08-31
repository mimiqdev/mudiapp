import Foundation
import HerdrKit
import XCTest
@testable import Mudi

final class Phase5MoshTests: XCTestCase {
    func testSavingThenLoadingRestoresAutomaticMoshAndSSHPreferences() async throws {
        let hostFile = Phase5HostFile()
        let firstApplication = makeMissingPhase5Application(hostFile: hostFile)
        let hosts = [
            phase5Host(preferredTransport: .automatic),
            phase5Host(preferredTransport: .mosh),
            phase5Host(preferredTransport: .ssh),
        ]

        for host in hosts {
            try await firstApplication.save(host)
        }

        let secondApplication = makeMissingPhase5Application(hostFile: hostFile)
        let loadedHosts = try await secondApplication.loadHosts()

        XCTAssertEqual(loadedHosts, hosts)
        XCTAssertEqual(
            loadedHosts.map(\.preferredTransport),
            [.automatic, .mosh, .ssh]
        )
    }

    func testAutomaticTransportFallsBackToSSHWhenMoshIsUnavailableAndReportsSSH() async throws {
        let host = phase5Host(preferredTransport: .automatic)
        let credentials = phase5Credentials()
        let sshTransport = Phase5TransportSpy(kind: .ssh)
        let moshTransport = Phase5TransportSpy(kind: .mosh, available: false)
        let application = makeMissingPhase5Application(
            keychain: Phase5Keychain(),
            sshTransport: sshTransport,
            moshTransport: moshTransport
        )
        try await application.save(host)
        try await application.save(credentials, for: host)

        let actualTransport = try await application.connect(to: host)
        let moshAttempts = await moshTransport.connectionAttempts()
        let sshAttempts = await sshTransport.connectionAttempts()
        let reportedTransport = await application.activeTransport()

        XCTAssertEqual(moshAttempts, 1, "Auto should try Mosh before falling back")
        XCTAssertEqual(sshAttempts, 1)
        XCTAssertEqual(actualTransport, .ssh)
        XCTAssertEqual(reportedTransport, .ssh)
    }

    func testAutomaticTransportReportsMoshWhenMoshIsAvailable() async throws {
        let host = phase5Host(preferredTransport: .automatic)
        let moshTransport = Phase5TransportSpy(kind: .mosh)
        let application = makeMissingPhase5Application(
            sshTransport: Phase5TransportSpy(kind: .ssh),
            moshTransport: moshTransport
        )
        try await application.save(host)
        try await application.save(phase5Credentials(), for: host)

        let actualTransport = try await application.connect(to: host)
        let moshAttempts = await moshTransport.connectionAttempts()
        let reportedTransport = await application.activeTransport()

        XCTAssertEqual(moshAttempts, 1)
        XCTAssertEqual(actualTransport, .mosh)
        XCTAssertEqual(reportedTransport, .mosh)
    }

    func testMoshUsesSavedSSHCredentialsAndDoesNotPutSecretsInHostFile() async throws {
        let host = phase5Host(preferredTransport: .mosh)
        let credentials = phase5Credentials()
        let hostFile = Phase5HostFile()
        let keychain = Phase5Keychain()
        let moshTransport = Phase5TransportSpy(kind: .mosh)
        let application = makeMissingPhase5Application(
            hostFile: hostFile,
            keychain: keychain,
            moshTransport: moshTransport
        )
        try await application.save(host)
        try await application.save(credentials, for: host)

        let storedCredentials = try await application.credentials(for: host)
        let actualTransport = try await application.connect(to: host)
        let moshRecords = await moshTransport.connectionRecords()
        let persistedDataValue = await hostFile.data()
        let persistedData = try XCTUnwrap(persistedDataValue)
        let persistedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: persistedData))
        let secretFields = ["password", "pem", "pemPrivateKey", "privateKey"]
        let secretMarkers = [credentials.password, credentials.pemPrivateKey].compactMap { $0 }

        XCTAssertEqual(storedCredentials, credentials)
        XCTAssertEqual(actualTransport, .mosh)
        XCTAssertEqual(moshRecords.map(\.credentials), [credentials])
        XCTAssertFalse(containsAnyKey(persistedObject, names: secretFields))
        XCTAssertFalse(dataContainsAny(persistedData, markers: secretMarkers))
    }

    private func containsAnyKey(_ value: Any, names: [String]) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: names.contains) {
                return true
            }
            return dictionary.values.contains { containsAnyKey($0, names: names) }
        }
        if let values = value as? [Any] {
            return values.contains { containsAnyKey($0, names: names) }
        }
        return false
    }

    private func dataContainsAny(_ data: Data, markers: [String]) -> Bool {
        markers.contains { data.range(of: Data($0.utf8)) != nil }
    }
}
