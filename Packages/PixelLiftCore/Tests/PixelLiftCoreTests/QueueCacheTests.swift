import Foundation
import XCTest
@testable import PixelLiftCore

final class QueueCacheTests: XCTestCase {
    func testDimensionsLimitAndEightTimesBoundary() throws {
        XCTAssertNoThrow(try ImageLimits.check(width: 1000, height: 500, scale: 8))
        XCTAssertThrowsError(try ImageLimits.check(width: 1000, height: 501, scale: 8))
        XCTAssertThrowsError(try ImageLimits.check(width: Int.max, height: Int.max, scale: 8))
        XCTAssertThrowsError(try ImageLimits.check(width: 0, height: 10))
    }

    func testCacheBudgetCommitDeletionAndPersistenceOfUserFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let userFile = root.appendingPathComponent("kept.png")
        try Data([10, 20]).write(to: userFile)
        let base = root.appendingPathComponent("cache")
        let directory = try CacheDirectory(base: base)
        XCTAssertThrowsError(try CacheDirectory(base: base)) {
            XCTAssertEqual($0 as? PixelLiftError, .cacheBusy)
        }
        let cache = ResultCache(directory: directory, limit: 10)
        let first = try await cache.reserve(bytes: 7)
        do {
            _ = try await cache.reserve(bytes: 4)
            XCTFail("Expected reservation failure")
        } catch {
            XCTAssertEqual(error as? PixelLiftError, .cacheFull)
        }

        try Data([1, 2, 3]).write(to: first.output)
        try await cache.commit(first)
        let usage = await cache.usage()
        XCTAssertEqual(usage, 3)
        let second = try await cache.reserve(bytes: 7)
        try Data([4, 5]).write(to: second.output)
        let remaining = await cache.clear()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.output.path))
        XCTAssertEqual(try Data(contentsOf: userFile), Data([10, 20]))
        let disk = try await cache.sizeOnDisk()
        XCTAssertEqual(disk, 0)
    }

    func testStaleSessionIsRemovedOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stale = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: stale.appendingPathComponent("orphan"))
        let directory = try CacheDirectory(base: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path), [])
    }

    @MainActor
    func testQueueRunsOnlyTwoJobsAndCanCancelWaitingJob() async throws {
        let queue = JobQueue<String>()
        let work = ActiveWork()
        queue.setLimit(2)
        let ids = (0..<4).map { _ in UUID() }
        let completed = expectation(description: "three successful jobs")
        completed.expectedFulfillmentCount = 3
        let canceled = expectation(description: "waiting job canceled")
        var finished: Set<UUID> = []
        queue.onUpdate = { id, update in
            switch update {
            case .completed:
                finished.insert(id)
                completed.fulfill()
            case .canceled:
                XCTAssertEqual(id, ids[3])
                canceled.fulfill()
            default: break
            }
        }
        queue.enqueue(ids.map { id in
            UpscaleJob(id: id) { _ in try await work.perform() }
        })
        queue.cancel(ids[3])
        await fulfillment(of: [completed, canceled], timeout: 5)
        let peak = await work.peak
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(finished, Set(ids.prefix(3)))
        XCTAssertEqual(queue.count, 0)
    }

    @MainActor
    func testQueueFailureRetryAndActiveCancellation() async throws {
        let queue = JobQueue<Int>()
        let id = UUID()
        let failed = expectation(description: "failure")
        queue.onUpdate = { _, update in
            if case .failed(let error) = update {
                XCTAssertEqual(error, .predictionFailed)
                failed.fulfill()
            }
        }
        queue.enqueue([UpscaleJob(id: id) { _ in throw PixelLiftError.predictionFailed }])
        await fulfillment(of: [failed], timeout: 2)

        let completed = expectation(description: "same id retried")
        queue.onUpdate = { _, update in
            if case .completed(let result) = update {
                XCTAssertEqual(result, 7)
                completed.fulfill()
            }
        }
        queue.enqueue([UpscaleJob(id: id) { _ in 7 }])
        await fulfillment(of: [completed], timeout: 2)

        let stopped = expectation(description: "active job canceled")
        queue.onUpdate = { _, update in
            if case .canceled = update { stopped.fulfill() }
        }
        queue.enqueue([UpscaleJob(id: id) { _ in
            try await Task.sleep(for: .seconds(30))
            return 0
        }])
        queue.cancel(id)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(queue.count, 0)
    }
}

private actor ActiveWork {
    private var active = 0
    private(set) var peak = 0

    func perform() async throws -> String {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(80))
        return "done"
    }
}
