import Foundation

/// Coalesces streamed deltas so the renderer is poked a few times/sec instead of
/// per token. Flush triggers: byte threshold, idle timeout, or explicit `finalize()`.
/// Mirrors Dia's `update-batcher` (256B / 250ms / done), tuned tighter for an
/// in-process native renderer (no IPC, so we can flush more often and stay cheap).
@MainActor
public final class DeltaCoalescer {
    private var pending = ""
    private var idleTask: Task<Void, Never>?
    private let byteThreshold: Int
    private let idle: Duration
    private let onFlush: @MainActor (String) -> Void

    public init(
        byteThreshold: Int = 64,
        idleMilliseconds: Int = 50,
        onFlush: @escaping @MainActor (String) -> Void
    ) {
        self.byteThreshold = byteThreshold
        self.idle = .milliseconds(idleMilliseconds)
        self.onFlush = onFlush
    }

    /// Buffer a streaming delta; flushes automatically on size or idle.
    public func buffer(_ delta: String) {
        pending += delta
        idleTask?.cancel()
        if pending.utf8.count >= byteThreshold {
            commit()
            return
        }
        let idle = self.idle
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: idle)
            guard let self, !Task.isCancelled else { return }
            self.commit()
        }
    }

    /// Flush everything immediately (call on stream end / cancel).
    public func finalize() {
        idleTask?.cancel()
        idleTask = nil
        commit()
    }

    private func commit() {
        guard !pending.isEmpty else { return }
        let chunk = pending
        pending = ""
        onFlush(chunk)
    }
}
