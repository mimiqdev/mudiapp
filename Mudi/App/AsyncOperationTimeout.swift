import Foundation
import HerdrKit

/// Runs an async operation with a deadline without waiting for an operation
/// that ignores cancellation. The abort hook lets the owner retire any
/// state associated with that late operation before a new connection starts.
func runWithTimeout<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value,
    onAbort: @escaping @Sendable () async -> Void
) async throws -> Value {
    let race = AsyncOperationTimeoutRace(
        timeout: timeout,
        operation: operation,
        onAbort: onAbort
    )
    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
        }
    }, onCancel: {
        race.cancel()
    })
}

private final class AsyncOperationTimeoutRace<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let timeout: Duration
    private let operation: @Sendable () async throws -> Value
    private let onAbort: @Sendable () async -> Void
    private var didResolve = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value,
        onAbort: @escaping @Sendable () async -> Void
    ) {
        self.timeout = timeout
        self.operation = operation
        self.onAbort = onAbort
    }

    func start(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let operationTask = Task { [operation, weak self] in
            do {
                let value = try await operation()
                self?.resolve(.success(value))
            } catch {
                self?.resolve(.failure(error))
            }
        }
        let timeoutTask = Task { [timeout, onAbort, weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                  self.resolve(.failure(ConnectionError.connectionTimedOut))
            else { return }
            await onAbort()
        }

        lock.lock()
        if didResolve {
            lock.unlock()
            operationTask.cancel()
            timeoutTask.cancel()
        } else {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func cancel() {
        guard resolve(.failure(CancellationError())) else { return }
        Task { [onAbort] in
            await onAbort()
        }
    }

    @discardableResult
    private func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            return false
        }
        didResolve = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        self.operationTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
        return true
    }
}
