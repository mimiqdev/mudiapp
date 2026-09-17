import Foundation
@preconcurrency import NIOCore

/// The timing policy used when a hostname has more than one address family.
///
/// ``ClientBootstrap.connect(host:port:)`` applies SwiftNIO's RFC 8305
/// Happy Eyeballs implementation. This value is the app-owned, testable
/// description of that policy: the alternate family starts after the same
/// 250-ms stagger and every candidate receives the cellular/VPN-safe connect
/// budget.
struct NetworkConnectionPolicy: Equatable, Sendable {
    let addressFamilyStagger: Duration
    let perAttemptTimeout: Duration
    let documentation: String

    /// A 60-second budget leaves room for a cellular tunnel or VPN/tailnet to
    /// become usable while Happy Eyeballs prevents a dead address family from
    /// consuming the whole budget first.
    static let documentedDefault = NetworkConnectionPolicy(
        addressFamilyStagger: .milliseconds(250),
        perAttemptTimeout: .nanoseconds(
            NIOSSHConnection.connectTimeout.nanoseconds
        ),
        documentation:
            "A 60-second SSH connect budget for cellular and VPN/tailnet paths; "
            + "dual-stack addresses use a 250ms Happy Eyeballs stagger."
    )

    func attemptPlan<Address: Equatable & Sendable>(
        for addresses: [Address]
    ) -> [NetworkConnectionAttempt<Address>] {
        addresses.enumerated().map { index, address in
            NetworkConnectionAttempt(
                address: address,
                startAfter: index == 0 ? .zero : addressFamilyStagger,
                timeout: perAttemptTimeout
            )
        }
    }
}

/// One scheduled address-family connection attempt.
struct NetworkConnectionAttempt<Address: Equatable & Sendable>:
    Equatable, Sendable {
    let address: Address
    /// Delay from the preceding scheduled attempt. The first attempt starts
    /// immediately.
    let startAfter: Duration
    let timeout: Duration
}

/// Races address-family connection attempts while retaining the first
/// successful address. Failed candidates do not cancel later candidates, but
/// a successful candidate cancels attempts that are still waiting or dialing.
enum NetworkConnectionStrategy {
    static func connect<Address: Equatable & Sendable>(
        to addresses: [Address],
        policy: NetworkConnectionPolicy,
        using connector: @escaping @Sendable (
            Address,
            Duration,
            Duration
        ) async throws -> Void
    ) async throws -> Address {
        let attempts = policy.attemptPlan(for: addresses)
        guard !attempts.isEmpty else {
            throw NetworkConnectionStrategyError.allAttemptsFailed
        }

        return try await withThrowingTaskGroup(of: Address?.self) { group in
            var elapsed = Duration.zero
            for attempt in attempts {
                elapsed += attempt.startAfter
                let scheduledAfter = elapsed
                group.addTask {
                    do {
                        if scheduledAfter > .zero {
                            try await Task.sleep(for: scheduledAfter)
                        } else {
                            try Task.checkCancellation()
                        }
                        try await connector(
                            attempt.address,
                            attempt.startAfter,
                            attempt.timeout
                        )
                        return attempt.address
                    } catch is CancellationError {
                        return nil
                    } catch {
                        return nil
                    }
                }
            }

            while let result = try await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }

            if Task.isCancelled {
                throw CancellationError()
            }
            throw NetworkConnectionStrategyError.allAttemptsFailed
        }
    }
}

enum NetworkConnectionStrategyError: Error, Equatable, Sendable {
    case allAttemptsFailed
}
