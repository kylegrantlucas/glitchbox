import Foundation

/// A process-wide FIFO gate admitting one multi-tool pipe chain at a time.
///
/// Each tool serializes itself inside its library, so two chains running at once can each hold
/// some tools' locks while blocking on a pipe whose other end waits for a lock the other chain
/// holds — a deadlock. Running whole chains one at a time removes the cycle.
actor ChainGate {
    static let shared = ChainGate()

    private var busy = false
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []

    /// Runs `body` once the gate is free, in arrival order. A task cancelled while queued
    /// throws `CancellationError` promptly and never runs `body`.
    nonisolated func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                // The cancel handler may already have run (and found nothing to remove).
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, c))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    /// Hands the gate straight to the next waiter (it stays busy), or frees it.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
