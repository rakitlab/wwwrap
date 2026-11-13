@testable import DownloadCore
import XCTest

final class PriorityAllocatorTests: XCTestCase {
    private let mb = 1024.0 * 1024
    private let a = UUID(), b = UUID(), c = UUID()

    /// Runs the allocator for a while, feeding back speeds from a simple model:
    /// each download gets min(cap, its server limit), and whatever the line has left over
    /// is shared equally by the uncapped ones.
    private func simulate(_ allocator: PriorityAllocator,
                          priorities: [UUID: DownloadPriority],
                          serverLimit: [UUID: Double] = [:],
                          userCap: [UUID: Double] = [:],
                          line: Double, globalLimit: Double = 0, rounds: Int = 60) -> [UUID: Double] {
        var speeds = priorities.mapValues { _ in line / Double(priorities.count) }
        var caps: [UUID: Double] = [:]
        for _ in 0..<rounds {
            let entries = priorities.map {
                PriorityAllocator.Entry(id: $0.key, priority: $0.value, speed: speeds[$0.key]!,
                                        userCap: userCap[$0.key] ?? 0)
            }
            caps = allocator.update(entries, globalLimit: globalLimit)
            let available = globalLimit > 0 ? min(line, globalLimit) : line
            // Fixed-point fill: capped ones take their cap, the rest split what's left.
            var got: [UUID: Double] = [:]
            var remaining = available
            var open = Set(priorities.keys)
            while !open.isEmpty {
                let each = remaining / Double(open.count)
                let limited = open.filter { id in
                    let limit = min(caps[id].flatMap { $0 > 0 ? $0 : nil } ?? .infinity,
                                    serverLimit[id] ?? .infinity)
                    return limit < each
                }
                if limited.isEmpty { for id in open { got[id] = each }; break }
                for id in limited {
                    let limit = min(caps[id].flatMap { $0 > 0 ? $0 : nil } ?? .infinity,
                                    serverLimit[id] ?? .infinity)
                    got[id] = limit
                    remaining -= limit
                    open.remove(id)
                }
            }
            speeds = got
        }
        return speeds
    }

    func testSamePriorityIsNeverCapped() {
        let allocator = PriorityAllocator()
        let caps = allocator.update([
            .init(id: a, priority: .normal, speed: 5 * mb),
            .init(id: b, priority: .normal, speed: 5 * mb),
        ], globalLimit: 0)
        XCTAssertEqual(caps[a], 0)
        XCTAssertEqual(caps[b], 0)
    }

    func testUserCapAppliesWithoutPriorities() {
        let allocator = PriorityAllocator()
        let caps = allocator.update([.init(id: a, priority: .normal, speed: 1 * mb, userCap: 512.0 * 1024)],
                                    globalLimit: 0)
        XCTAssertEqual(caps[a], 512.0 * 1024)
    }

    func testHighPriorityGetsTheBiggerShare() {
        let speeds = simulate(PriorityAllocator(), priorities: [a: .high, b: .low], line: 20 * mb)
        // 3 : 1 → about 15 and 5 MB/s.
        XCTAssertEqual(speeds[a]! / mb, 15, accuracy: 1.5)
        XCTAssertEqual(speeds[b]! / mb, 5, accuracy: 1.5)
    }

    func testThreeLevelsFollowWeights() {
        let speeds = simulate(PriorityAllocator(), priorities: [a: .high, b: .normal, c: .low],
                              line: 12 * mb, globalLimit: 12 * mb)
        XCTAssertGreaterThan(speeds[a]!, speeds[b]!)
        XCTAssertGreaterThan(speeds[b]!, speeds[c]!)
        XCTAssertEqual(speeds[b]! / mb, 4, accuracy: 1)
        XCTAssertEqual(speeds[c]! / mb, 2, accuracy: 1)
    }

    func testSlowServerOnHighPriorityDoesNotWasteTheLine() {
        // The important download's server only gives 2 MB/s: the low one should use the rest.
        let speeds = simulate(PriorityAllocator(), priorities: [a: .high, b: .low],
                              serverLimit: [a: 2 * mb], line: 20 * mb)
        XCTAssertEqual(speeds[a]! / mb, 2, accuracy: 0.1)
        XCTAssertGreaterThan(speeds[b]! / mb, 14)
    }

    func testLowPriorityNeverStarves() {
        let allocator = PriorityAllocator()
        let caps = allocator.update([
            .init(id: a, priority: .high, speed: 100.0 * 1024),
            .init(id: b, priority: .low, speed: 0),
        ], globalLimit: 10.0 * 1024)
        XCTAssertGreaterThanOrEqual(caps[b]!, PriorityAllocator.floor)
    }

    func testUserCapStillLimitsLowPriority() {
        let speeds = simulate(PriorityAllocator(), priorities: [a: .high, b: .low],
                              serverLimit: [a: 1 * mb], userCap: [b: 3 * mb], line: 20 * mb)
        XCTAssertLessThanOrEqual(speeds[b]!, 3 * mb + 1)
    }

    func testRetuneKeepsWaitersWaitingOnSmallChanges() async throws {
        let limiter = BandwidthLimiter(bytesPerSecond: 1 << 20, burst: 0)
        let start = Date()
        let waiter = Task { try await limiter.acquire(1 << 20) } // ~1 s
        try await Task.sleep(nanoseconds: 100_000_000)
        limiter.retune(1_100_000) // small raise: must not release the waiter
        try await waiter.value
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.8)
    }
}
