import Foundation

/// Priority of a download. Higher priority gets a bigger share when downloads run together,
/// and is started first from the queue.
public enum DownloadPriority: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 1, normal = 2, high = 3

    /// Bandwidth weight: high : normal : low = 3 : 2 : 1.
    public var weight: Double { Double(rawValue) }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Splits bandwidth between parallel downloads by priority and applies per-download caps.
///
/// Rules:
/// - Downloads of the highest priority present are never slowed by priority (only by their own
///   cap and the global limit), so the top download always gets everything it can take.
/// - Every lower-priority download is capped at its weighted share of the budget
///   (`budget × weight / Σweights`), plus whatever the others leave unused. Leftover matters
///   when the important download is slow because of its *server*: then holding the others
///   back would only waste the line.
/// - Caps move toward their target gradually (each update closes 30 % of the gap), because
///   measured speeds react to a new cap only after a moment.
/// - If every running download has the same priority, nothing is capped by priority.
///
/// The budget is the global speed limit when one is set, otherwise an estimate of the line's
/// capacity: the highest total speed seen recently, slowly decaying.
///
/// Not thread-safe; owned by the download manager on the main actor.
public final class PriorityAllocator {
    public struct Entry: Equatable {
        public var id: UUID
        public var priority: DownloadPriority
        /// Measured speed in bytes per second.
        public var speed: Double
        /// The user's own cap for this download in bytes per second; 0 = none.
        public var userCap: Double

        public init(id: UUID, priority: DownloadPriority, speed: Double, userCap: Double = 0) {
            self.id = id
            self.priority = priority
            self.speed = speed
            self.userCap = userCap
        }
    }

    /// A capped download never drops below this, so low priority still makes progress.
    public static let floor: Double = 64 * 1024
    /// How fast caps move toward their target per update (0…1).
    public var smoothing: Double = 0.3
    /// Per-update decay of the capacity estimate (0.995 at 2 updates/s ≈ 70 s half-life).
    public var peakDecay: Double = 0.995

    private var priorityCaps: [UUID: Double] = [:]
    public private(set) var capacityEstimate: Double = 0

    public init() {}

    /// Returns the cap for each entry in bytes per second (0 = uncapped).
    /// - Parameter globalLimit: the global cap in bytes per second, 0 when unlimited.
    public func update(_ entries: [Entry], globalLimit: Double) -> [UUID: Double] {
        let total = entries.reduce(0) { $0 + $1.speed }
        capacityEstimate = max(total, capacityEstimate * peakDecay)
        let budget = globalLimit > 0 ? globalLimit : capacityEstimate

        let ids = Set(entries.map(\.id))
        priorityCaps = priorityCaps.filter { ids.contains($0.key) }

        var result: [UUID: Double] = [:]
        for e in entries { result[e.id] = e.userCap }

        guard let top = entries.map(\.priority).max(),
              entries.contains(where: { $0.priority != top }),
              budget > 0 else {
            priorityCaps.removeAll()
            return result
        }

        let weightSum = entries.reduce(0) { $0 + $1.priority.weight }
        func share(_ e: Entry) -> Double { budget * e.priority.weight / weightSum }
        // What downloads leave on the table, including bandwidth a download can't use because
        // of its own cap (10 % tolerance so normal jitter isn't "spare").
        let spare = entries.reduce(0) { $0 + max(0, share($1) - $1.speed * 1.1) }
        let lower = entries.filter { $0.priority != top }
        let lowerWeight = lower.reduce(0) { $0 + $1.priority.weight }

        for e in lower {
            let target = share(e) + spare * e.priority.weight / lowerWeight
            let previous = priorityCaps[e.id] ?? share(e)
            var cap = previous + (target - previous) * smoothing
            cap = max(Self.floor, cap)
            priorityCaps[e.id] = cap
            result[e.id] = e.userCap > 0 ? min(e.userCap, cap) : cap
        }
        // Top-priority downloads: only their own cap applies.
        for e in entries where e.priority == top { priorityCaps[e.id] = nil }
        return result
    }

    /// Forget everything (e.g. after all downloads stopped).
    public func reset() {
        priorityCaps.removeAll()
        capacityEstimate = 0
    }
}
