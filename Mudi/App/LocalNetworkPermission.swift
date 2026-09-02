import Foundation
import Network
import os

/// Diagnostics for the local-network probe: device-side console reads are
/// locked down, so the trace is also appended to a file in the app
/// container that can be pulled with devicectl after a manual run.
///
/// Remove once the alert behavior is confirmed on device (#if DEBUG keeps
/// it out of release builds).
enum ProbeTrace {
    private static let logger = Logger(
        subsystem: "dev.mudi.mobile", category: "local-network-probe"
    )
    #if DEBUG
    private static let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("probe-trace.log")
    #endif

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        #if DEBUG
        let stamp = DateFormatter.localizedString(
            from: Date(), dateStyle: .none, timeStyle: .medium
        )
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}

/// Production gate backed by a Bonjour browse probe. iOS exposes no direct
/// read API for the Local Network privacy decision, but Bonjour browsing is
/// itself gated by it: a permitted browse becomes `.ready` while a denied
/// one fails with the DNS-SD policy error.
///
/// Ordering guarantee (explain first, then ask): starting a browse is what
/// triggers the iOS Local Network system alert, so ONLY `requestPermission`
/// probes. `status` is passive — it reports the last known result of a
/// request in this process and otherwise `.undetermined` — so the
/// explanation surface always appears before any system alert.
actor SystemLocalNetworkPermissionGate: LocalNetworkPermissionGate {
    /// kDNSServiceErr_PolicyDenied — surfaced when the Local Network
    /// permission is denied for the app.
    fileprivate static let policyDeniedDNSSDError = -65570

    /// Service types declared in NSBonjourServices (project.yml). iOS only
    /// honors (and only alerts for) Bonjour browsing of declared types.
    static let bonjourServiceTypes = [
        "_services._dns-sd._udp",
        "_ssh._tcp",
    ]

    private var lastKnownStatus: LocalNetworkPermissionStatus?

    /// Passive read: never starts a browse and never triggers the iOS
    /// Local Network alert. The explanation surface must always win the
    /// race against the system dialog.
    ///
    /// Accepted trade-off (review r2-f2): a fresh process cannot know a
    /// pre-existing grant, so an install with an unset onboarding flag
    /// (e.g. upgrading from a pre-phase-7 build that already holds Local
    /// Network permission) sees the explanation once and taps Continue;
    /// the probe then resolves instantly without any dialog. Manual
    /// acceptance notes must record this.
    func status() async -> LocalNetworkPermissionStatus {
        lastKnownStatus ?? .undetermined
    }

    /// The only alert trigger: starts the browse probe and remembers the
    /// outcome for passive `status` reads later in the same process. The
    /// timeout only bounds the wait - completion is event-driven (results
    /// answered / policy failure), so it fires as soon as the decision is
    /// observable; the budget leaves the user time to answer the alert.
    func requestPermission() async -> LocalNetworkPermissionStatus {
        ProbeTrace.log("requestPermission start")
        let status = await probe(timeout: .seconds(20))
        ProbeTrace.log("requestPermission end \(status)")
        lastKnownStatus = status
        return status
    }

    private func probe(timeout: Duration) async -> LocalNetworkPermissionStatus {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let monitor = LocalNetworkProbeMonitor(timeout: timeout) { status in
                    continuation.resume(returning: status)
                }
                monitor.start()
            }
        }
    }
}

/// Grant evidence for a browse event. An EMPTY result set is not proof:
/// NWBrowser commonly delivers an empty initial set at start, including
/// while the system alert is still pending, and treating it as granted
/// would cancel the connection trigger that actually presents the alert.
/// Proof is a non-empty result set or an `.added` change.
enum LocalNetworkProbeEvidence {
    static func browseEventProvesGrant(
        resultsCount: Int,
        hasAddedChange: Bool
    ) -> Bool {
        resultsCount > 0 || hasAddedChange
    }

    static func browseEventProvesGrant(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) -> Bool {
        browseEventProvesGrant(
            resultsCount: results.count,
            hasAddedChange: changes.contains { change in
                if case .added = change { return true }
                return false
            }
        )
    }
}

/// Drives the local-network probe until it proves the decision or the
/// window closes. Two local-network triggers run together from t=0:
///
/// 1. A Bonjour browse of the DECLARED `_ssh._tcp` service type. (The
///    meta service `_services._dns-sd._udp` is rejected outright by
///    NWBrowser on iOS 27 with kDNSServiceErr_BadParam, whether or not a
///    domain is given - verified on device - so it is not browsed.)
/// 2. An NWConnection to a Bonjour endpoint: resolving the service name
///    is itself a local-network mDNS query, and on devices where browsing
///    alone does not trip the privacy gate, the connection path is the
///    one that demonstrably fires the system alert (matching the proven
///    behavior of a plain SSH TCP connect).
///
/// Evidence semantics: answered browse results or a connected NWConnection
/// = granted (queries/connections are held while the system alert is
/// pending, so any answer implies a decision); the DNS policy error =
/// denied; everything else (BadParam, resolution/transport failures on a
/// network with no such service) retires only that trigger - they are not
/// user decisions. The window only bounds how long the probe waits.
@MainActor
private final class LocalNetworkProbeMonitor {
    private let browser: NWBrowser
    private let connection: NWConnection
    private let timeout: Duration
    private let finish: @MainActor (LocalNetworkPermissionStatus) -> Void
    private var timeoutTask: Task<Void, Never>?
    /// Triggers still attempting; the probe ends in .undetermined only
    /// when both have retired without a decision.
    private var liveTriggerCount = 0
    private var didFinish = false

    init(
        timeout: Duration,
        finish: @escaping @MainActor (LocalNetworkPermissionStatus) -> Void
    ) {
        browser = NWBrowser(
            for: .bonjour(type: "_ssh._tcp", domain: nil),
            using: .tcp
        )
        // No host needs to exist: resolving the endpoint is the trigger.
        connection = NWConnection(
            to: .service(
                name: "mudi-local-network-probe",
                type: "_ssh._tcp",
                domain: "local.",
                interface: nil
            ),
            using: .tcp
        )
        self.timeout = timeout
        self.finish = finish
    }

    func start() {
        ProbeTrace.log("browse start _ssh._tcp")
        wireBrowser(browser)
        browser.start(queue: .main)
        ProbeTrace.log("connection trigger start")
        wireConnection(connection)
        connection.start(queue: .main)
        liveTriggerCount = 2
        // Strong self: the monitor must stay alive until it completes, or
        // the timeout would never fire and the probe continuation would
        // leak.
        timeoutTask = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            ProbeTrace.log("timeout window closed")
            await self.complete(with: .undetermined)
        }
    }

    private func wireBrowser(_ browser: NWBrowser) {
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { @MainActor in
                ProbeTrace.log(
                    "browse results count=\(results.count) changes=\(changes.count)"
                )
                guard LocalNetworkProbeEvidence.browseEventProvesGrant(
                    results: results,
                    changes: changes
                ) else {
                    // Empty initial set: not a decision - keep both
                    // triggers alive so the alert can still fire.
                    return
                }
                self.complete(with: .granted)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                ProbeTrace.log("browse state \(String(describing: state))")
                switch state {
                case .failed(let error):
                    if case let .dns(code) = error,
                       code == SystemLocalNetworkPermissionGate
                           .policyDeniedDNSSDError {
                        self.complete(with: .denied)
                    } else {
                        self.retireBrowser(reason: "\(error)")
                    }
                case .ready, .waiting, .setup, .cancelled:
                    // .ready is NOT proof of permission (it fires the
                    // moment the browse is set up); .waiting includes the
                    // pending system alert. The triggers stay live.
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func wireConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                ProbeTrace.log("conn state \(String(describing: state))")
                switch state {
                case .ready:
                    // Connected to a real service: local-network access is
                    // permitted.
                    self.complete(with: .granted)
                case .failed(let error):
                    if let nsError = error as? NWError,
                       case let .dns(code) = nsError,
                       code == SystemLocalNetworkPermissionGate
                           .policyDeniedDNSSDError {
                        self.complete(with: .denied)
                    } else {
                        self.retireConnection(reason: "\(error)")
                    }
                case .waiting, .preparing, .setup, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func retireBrowser(reason: String) {
        ProbeTrace.log("browse retired (\(reason))")
        browser.cancel()
        liveTriggerCount -= 1
        if liveTriggerCount == 0 { complete(with: .undetermined) }
    }

    private func retireConnection(reason: String) {
        ProbeTrace.log("conn retired (\(reason))")
        connection.cancel()
        liveTriggerCount -= 1
        if liveTriggerCount == 0 { complete(with: .undetermined) }
    }

    private func complete(with status: LocalNetworkPermissionStatus) {
        guard !didFinish else { return }
        didFinish = true
        ProbeTrace.log("complete \(status)")
        timeoutTask?.cancel()
        browser.cancel()
        connection.cancel()
        finish(status)
    }
}

/// The system-facing state used by the first-launch local-network gate.
///
/// The concrete iOS permission request is intentionally supplied by the app
/// layer so startup behavior can be exercised without invoking system APIs.
enum LocalNetworkPermissionStatus: Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

protocol LocalNetworkPermissionGate: Sendable {
    func status() async -> LocalNetworkPermissionStatus
    func requestPermission() async -> LocalNetworkPermissionStatus
}
