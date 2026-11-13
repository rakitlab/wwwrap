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
/// The line's capacity is unknown (Starlink swings a lot), so instead of dividing a guessed
/// budget the allocator works *relative to the most important downloads*:
///
/// - Downloads of the highest priority present ("top") are never slowed by priority.
/// - Each lower download is capped at `top speed per weight × its weight × boost`. With
///   boost 1 that is exactly the 3 : 2 : 1 ratio, and it is stable: if the top download gets
///   more, the others are allowed more too.
/// - The boost finds out whether holding a download back actually helps. Every window
///   (`window` updates) a download that is pressing against its cap gets the boost raised
///   (×`probeStep`). If the top downloads slow down noticeably in the next window, they were
///   competing for the line: the boost is halved and stays put for a few windows. If they
///   don't, the top download is limited by its own server, and the others may keep the room.
///   So a slow server on the important file never wastes the line.
/// - A capped download never drops below `floor`, so low priority still makes progress.
/// - If every running download has the same priority, nothing is capped by priority.
/// - The user's own per-download cap always applies on top.
///
/// Call `update` at a steady rate (the app does it twice a second). Not thread-safe; owned by
/// the download manager on the main actor.
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

    public static let floor: Double = 64 * 1024
    /// Updates per probe window (8 × 0.5 s = 4 s).
    public var window = 8
    public var probeStep = 1.5
    public var backOff = 2.0
    /// A drop of the top downloads' speed bigger than this after a probe means contention.
    public var contentionDrop = 0.07
    /// Windows to wait after backing off before probing again.
    public var holdWindows = 3
    public var maxBoost = 1000.0

    private var boost: [UUID: Double] = [:]
    private var priorityCaps: [UUID: Double] = [:]
    private var topSamples: [Double] = []
    private var previousTop: Double?
    private var topIDs: Set<UUID> = []
    private var probing = false
    private var hold = 0
    private var updates = 0

    public init() {}

    /// Returns the cap for each entry in bytes per second (0 = uncapped).
    public func update(_ entries: [Entry]) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        for e in entries { result[e.id] = e.userCap }

        guard let top = entries.map(\.priority).max(),
              entries.contains(where: { $0.priority != top }) else {
            reset()
            return result
        }

        let topEntries = entries.filter { $0.priority == top }
        let lower = entries.filter { $0.priority != top }
        let currentTopIDs = Set(topEntries.map(\.id))
        if currentTopIDs != topIDs {
            // Different top downloads: earlier measurements say nothing about them.
            topIDs = currentTopIDs
            topSamples.removeAll()
            previousTop = nil
            probing = false
        }
        let lowerIDs = Set(lower.map(\.id))
        boost = boost.filter { lowerIDs.contains($0.key) }

        let topSpeed = topEntries.reduce(0) { $0 + $1.speed }
        let topWeight = topEntries.reduce(0) { $0 + $1.priority.weight }
        topSamples.append(topSpeed)
        updates += 1

        if updates % max(1, window) == 0, !topSamples.isEmpty {
            let average = topSamples.reduce(0, +) / Double(topSamples.count)
            topSamples.removeAll()
            if probing, let previous = previousTop, average < previous * (1 - contentionDrop) {
                for e in lower { boost[e.id] = max(1, (boost[e.id] ?? 1) / backOff) }
                hold = holdWindows
            } else if hold > 0 {
                hold -= 1
            }
            probing = false
            if hold == 0 {
                // Probe only downloads that are actually held back by their priority cap.
                let pressing = lower.filter { e in
                    guard let cap = priorityCaps[e.id] else { return false }
                    let byPriority = e.userCap == 0 || cap < e.userCap
                    return byPriority && e.speed >= 0.85 * cap
                }
                for e in pressing { boost[e.id] = min(maxBoost, (boost[e.id] ?? 1) * probeStep) }
                probing = !pressing.isEmpty
            }
            previousTop = average
        }

        var caps: [UUID: Double] = [:]
        for e in lower {
            let cap = max(Self.floor, topSpeed / max(1, topWeight) * e.priority.weight * (boost[e.id] ?? 1))
            caps[e.id] = cap
            result[e.id] = e.userCap > 0 ? min(e.userCap, cap) : cap
        }
        priorityCaps = caps
        return result
    }

    /// Forget everything (e.g. once downloads no longer have mixed priorities).
    public func reset() {
        boost.removeAll()
        priorityCaps.removeAll()
        topSamples.removeAll()
        previousTop = nil
        topIDs.removeAll()
        probing = false
        hold = 0
    }
}
