import Foundation

/// A shared speed cap for every connection of every download.
///
/// Workers call `acquire(_:)` for each chunk *before* acknowledging it to the stream. While
/// a worker waits, its stream buffer fills, `HTTPByteStream` suspends the URLSession task and
/// the TCP window closes, so the server really slows down: the limit holds on the wire, not
/// only on disk.
///
/// Algorithm: GCRA (virtual scheduling). Each acquire pushes a "theoretical arrival time"
/// forward by `bytes / rate`; a caller waits only for the part of that time beyond a small
/// burst allowance. Fair across workers, O(1), no timer thread. `limit == 0` means no cap.
public final class BandwidthLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Double = 0           // bytes per second, 0 = unlimited
    private var tat: TimeInterval = 0      // theoretical arrival time
    private var generation = 0             // bumps on every limit change
    /// How much may arrive at once before callers start waiting (seconds of `rate`).
    private let burst: TimeInterval

    public init(bytesPerSecond: Int64 = 0, burst: TimeInterval = 0.25) {
        self.burst = burst
        setLimit(bytesPerSecond)
    }

    /// Current cap in bytes per second; 0 = unlimited.
    public var limit: Int64 {
        lock.lock(); defer { lock.unlock() }
        return Int64(rate)
    }

    /// Changes the cap immediately; callers waiting under the old cap are released.
    public func setLimit(_ bytesPerSecond: Int64) {
        lock.lock()
        rate = Double(max(0, bytesPerSecond))
        tat = Self.now()
        generation += 1
        lock.unlock()
    }

    /// Adjusts the cap for frequent, small corrections (the priority allocator calls this twice
    /// a second). Unlike `setLimit`, a lower or slightly higher rate keeps the schedule and lets
    /// current waiters finish their wait, so retuning can't be used to skip the cap. Only a big
    /// raise (≥ 1.5×) or removing the cap releases waiters, so the new speed applies at once.
    public func retune(_ bytesPerSecond: Int64) {
        let new = Double(max(0, bytesPerSecond))
        lock.lock()
        defer { lock.unlock() }
        guard new != rate else { return }
        if new == 0 || rate == 0 || new >= rate * 1.5 {
            rate = new
            tat = Self.now()
            generation += 1
        } else {
            rate = new
        }
    }

    /// Waits until `bytes` may pass under the current cap. Throws on task cancellation.
    public func acquire(_ bytes: Int) async throws {
        guard bytes > 0 else { return }
        lock.lock()
        guard rate > 0 else { lock.unlock(); return }
        let now = Self.now()
        tat = max(tat, now) + Double(bytes) / rate
        var wait = tat - now - burst
        let myGeneration = generation
        lock.unlock()

        // Sleep in short slices so a raised or removed cap takes effect within a moment.
        while wait > 0 {
            let slice = min(wait, 0.25)
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            wait -= slice
            lock.lock()
            let changed = generation != myGeneration
            lock.unlock()
            if changed { return }
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
