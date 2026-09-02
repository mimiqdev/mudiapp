import XCTest
@testable import Mudi

/// Fresh-install Local Network onboarding (device regression): iOS only
/// fires the Local Network alert for Bonjour browsing when the browsed
/// service types are declared in NSBonjourServices, and the probe must
/// fall back from the meta-browse to the declared SSH type.
final class Phase7BonjourServicesTests: XCTestCase {
    func testDeclaredServiceTypesIncludeMetaBrowseAndSSH() {
        let declared = SystemLocalNetworkPermissionGate.bonjourServiceTypes
        XCTAssertTrue(
            declared.contains("_services._dns-sd._udp"),
            "The meta-browse (every service type) must be declared"
        )
        XCTAssertTrue(
            declared.contains("_ssh._tcp"),
            "The SSH fallback probe type must be declared - undeclared "
                + "types browse silently and never trigger the alert"
        )
    }

    func testEmptyBrowseEventIsNotGrantProof() {
        // An empty initial set (common at browse start, alert pending)
        // must not complete the probe as granted - that would cancel the
        // connection trigger that actually presents the system alert.
        XCTAssertFalse(
            LocalNetworkProbeEvidence.browseEventProvesGrant(
                resultsCount: 0,
                hasAddedChange: false
            )
        )
    }

    func testAnsweredBrowseEventIsGrantProof() {
        // A non-empty result set is an answered query: queries are held
        // while the alert is pending, so answers imply a decision.
        XCTAssertTrue(
            LocalNetworkProbeEvidence.browseEventProvesGrant(
                resultsCount: 1,
                hasAddedChange: false
            )
        )
        // An added change alone is also a real discovery event.
        XCTAssertTrue(
            LocalNetworkProbeEvidence.browseEventProvesGrant(
                resultsCount: 0,
                hasAddedChange: true
            )
        )
    }

    func testProjectWiresTheMergedPlistWithBonjourServices() throws {
        // NSBonjourServices has no INFOPLIST_KEY_* build setting: it is
        // merged in from Mudi/Info.plist via INFOPLIST_FILE +
        // GENERATE_INFOPLIST_FILE. Both halves of that wiring are load
        // bearing - dropping either silently disables the alert.
        //
        // The repo files only exist on the build machine; device runs
        // skip (CI/simulator runs assert).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MudiTests
            .deletingLastPathComponent()  // repo root
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("project.yml").path
        ) else {
            throw XCTSkip("Repo files are unavailable on-device")
        }
        let projectYML = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(
            projectYML.contains("INFOPLIST_FILE: Mudi/Info.plist"),
            "project.yml must wire the merged Info.plist"
        )
        XCTAssertTrue(
            projectYML.contains("GENERATE_INFOPLIST_FILE"),
            "Generated plist content (usage description, orientations) "
                + "must stay enabled"
        )
        let infoPlist = try String(
            contentsOf: root.appendingPathComponent("Mudi/Info.plist"),
            encoding: .utf8
        )
        XCTAssertTrue(infoPlist.contains("NSBonjourServices"))
        XCTAssertTrue(infoPlist.contains("_services._dns-sd._udp"))
        XCTAssertTrue(infoPlist.contains("_ssh._tcp"))
    }
}
