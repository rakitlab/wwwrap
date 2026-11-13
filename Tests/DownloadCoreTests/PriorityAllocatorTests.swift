@testable import DownloadCore
import XCTest

final class PriorityAllocatorTests: XCTestCase {
    private let mb = 1024.0 * 1024
    private let a = UUID(), b = UUID(), c = UUID()

    /// Runs the allocator against a simple network model and returns the average speeds over
    /// the second half: each download gets min(cap, its server limit), and whatever the line
    /// has left is shared equally by the rest (TCP fairness).
    private func simulate(priorities: [UUID: DownloadPriority],
                          serverLimit: [UUID: Double] = [:],
                          userCap: [UUID: Double] = [:],
                          line: Double, rounds: Int = 1200) -> [UUID: Double] {
        let allocator = PriorityAllocator()
        let ids = Array(priorities.keys)
        var speeds = Dictionary(uniqueKeysWithValues: ids.map { ($0, line / Double(ids.count)) })
        var average = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.0) })
        for round in 0..<rounds {
            let entries = ids.map {
                PriorityAllocator.Entry(id: $0, priority: priorities[$0]!, speed: speeds[$0]!,
                                        userCap: userCap[$0] ?? 0)
            }
            let caps = allocator.update(entries)
            func limit(_ id: UUID) -> Double {
                let cap = caps[id] ?? 0
                return min(cap > 0 ? cap : .infinity, serverLimit[id] ?? .infinity)
            }
            var got: [UUID: Double] = [:]
            var remaining = line
            var open = Set(ids)
            while !open.isEmpty {
                let each = remaining / Double(open.count)
                let limited = open.filter { limit($0) < each }
                if limited.isEmpty { for id in open { got[id] = each }; break }
                for id in limited {
                    got[id] = limit(id)
                    remaining -= limit(id)
                    open.remove(id)
                }
            }
            speeds = got
            if round >= rounds / 2 {
                for id in ids { average[id]! += got[id]! / Double(rounds - rounds / 2) }
            }
        }
        return average
    }

    func testSamePriorityIsNeverCapped() {
        let caps = PriorityAllocator().update([
            .init(id: a, priority: .normal, speed: 5 * mb),
            .init(id: b, priority: .normal, speed: 5 * mb),
        ])
        XCTAssertEqual(caps[a], 0)
        XCTAssertEqual(caps[b], 0)
    }

    func testUserCapAppliesWithoutPriorities() {
        let caps = PriorityAllocator().update([
            .init(id: a, priority: .normal, speed: 1 * mb, userCap: 512.0 * 1024),
        ])
        XCTAssertEqual(caps[a], 512.0 * 1024)
    }

    func testHighPriorityGetsTheBiggerShare() {
        let speeds = simulate(priorities: [a: .high, b: .low], line: 20 * mb)
        // 3 : 1 → about 15 and 5 MB/s (probing costs a little).
        XCTAssertEqual(speeds[a]! / mb, 15, accuracy: 1.5)
        XCTAssertEqual(speeds[b]! / mb, 5, accuracy: 1.5)
    }

    func testThreeLevelsFollowWeights() {
        let speeds = simulate(priorities: [a: .high, b: .normal, c: .low], line: 12 * mb)
        XCTAssertGreaterThan(speeds[a]!, speeds[b]!)
        XCTAssertGreaterThan(speeds[b]!, speeds[c]!)
        XCTAssertEqual(speeds[a]! / mb, 6, accuracy: 1)
        XCTAssertEqual(speeds[c]! / mb, 2, accuracy: 1)
    }

    func testSlowServerOnHighPriorityDoesNotWasteTheLine() {
        // The important download's server only gives 2 MB/s: the low one should use the rest.
        let speeds = simulate(priorities: [a: .high, b: .low], serverLimit: [a: 2 * mb], line: 20 * mb)
        XCTAssertEqual(speeds[a]! / mb, 2, accuracy: 0.1)
        XCTAssertGreaterThan(speeds[b]! / mb, 15)
    }

    func testUserCapStillLimitsLowPriority() {
        let speeds = simulate(priorities: [a: .high, b: .low],
                              serverLimit: [a: 1 * mb], userCap: [b: 3 * mb], line: 20 * mb)
        XCTAssertEqual(speeds[b]! / mb, 3, accuracy: 0.1)
    }

    func testLowPriorityNeverStarves() {
        let caps = PriorityAllocator().update([
            .init(id: a, priority: .high, speed: 0),
            .init(id: b, priority: .low, speed: 0),
        ])
        XCTAssertGreaterThanOrEqual(caps[b]!, PriorityAllocator.floor)
        XCTAssertEqual(caps[a], 0)
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
