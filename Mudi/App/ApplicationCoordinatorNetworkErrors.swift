import Foundation
import HerdrKit
@preconcurrency import NIO

extension ApplicationCoordinator {
    func mapConnectionError(_ error: Error) -> ConnectionError {
        if let error = error as? ConnectionError {
            return error
        }
        if let networkError = mapNetworkConnectionError(error) {
            return networkError
        }
        if error is TransportSelectionError {
            return .moshUnavailable
        }
        if let error = error as? SSHShellError {
            switch error {
            case .authenticationFailed, .connectionFailed, .commandExecutionUnavailable, .notConnected:
                return .connectionFailed
            case .alreadyConnected:
                return .connectionFailed
            }
        }
        return .connectionFailed
    }

    /// Only transport failures may advance to another saved address. SSH
    /// authentication and host-key errors deliberately return false even when
    /// they eventually map to the same presentable connection error.
    func isRecoverableNetworkAddressError(_ error: Error) -> Bool {
        if error is SSHClientError {
            return false
        }
        if let shellError = error as? SSHShellError {
            switch shellError {
            case .connectionFailed:
                return true
            case .authenticationFailed,
                 .commandExecutionUnavailable,
                 .notConnected,
                 .alreadyConnected:
                return false
            }
        }
        if let connectionError = error as? ConnectionError {
            switch connectionError {
            case .connectionFailed,
                 .connectionTimedOut,
                 .hostUnreachable,
                 .connectionRefused:
                return true
            case .moshUnavailable,
                 .hostKeyRejected,
                 .hostKeyMismatch:
                return false
            }
        }
        return mapNetworkConnectionError(error) != nil
    }

    /// Converts NIO's transport details at the application boundary. The
    /// coordinator never lets NIO/NIOSSH descriptions reach the UI.
    private func mapNetworkConnectionError(_ error: Error) -> ConnectionError? {
        if let error = error as? ChannelError {
            if case .connectTimeout = error {
                return .connectionTimedOut
            }
            return nil
        }

        if let error = error as? IOError {
            return mapNetworkErrno(error.errnoCode)
        }

        if let error = error as? NIOConnectionError {
            for failure in error.connectionErrors {
                if let mapped = mapNetworkConnectionError(failure.error) {
                    return mapped
                }
            }
            if error.dnsAError != nil || error.dnsAAAAError != nil {
                return .hostUnreachable
            }
            return nil
        }

        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else {
            return nil
        }
        return mapNetworkErrno(CInt(nsError.code))
    }

    private func mapNetworkErrno(_ errno: CInt) -> ConnectionError? {
        switch errno {
        case ETIMEDOUT:
            return .connectionTimedOut
        case ECONNREFUSED:
            return .connectionRefused
        case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EADDRNOTAVAIL:
            return .hostUnreachable
        default:
            return nil
        }
    }
}
