//
//  ProcessUsageAggregatorTests.swift
//  FlowTraceTests
//
//  End-to-end coverage of the per-app usage pipeline: frames go in through
//  `ProcessUsageAggregator.feed`, minute rollover flushes them, and the
//  assertions read the result back out of a real (temporary) SQLite database
//  via `HistoryPersistence.processUsage`.
//
//  Deliberately not a mirror of the logic. The standalone script this
//  replaces re-implemented the accumulator by hand and had already drifted
//  from the real one: it had no equivalent of `seenPids`, so it asserted that
//  a process counts from its *first* frame, while production drops that frame
//  as cumulative-since-launch.
//

import XCTest
@testable import FlowTrace

final class ProcessUsageAggregatorTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            // The db runs in WAL mode, so the sidecar files go too.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        tempURLs = []
        super.tearDown()
    }

    /// `HistoryPersistence` accepts any URL, so the pipeline can be exercised
    /// against a throwaway database instead of the user's real one.
    private func makePersistence() throws -> HistoryPersistence {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-usage-\(UUID().uuidString).sqlite3")
        tempURLs.append(url)
        return try XCTUnwrap(HistoryPersistence(dbURL: url, retentionSeconds: 3600))
    }

    private func entity(_ pid: Int, _ name: String, _ inBps: Int, _ outBps: Int) -> ProcessEntity {
        ProcessEntity(pid: pid, name: name, inBytesPerSec: inBps, outBytesPerSec: outBps)
    }

    /// `feed` accumulates on its own private queue and the read runs on the
    /// persistence queue, and neither exposes a completion — so the result is
    /// polled until it settles. A genuinely empty expectation therefore costs
    /// one short timeout rather than hanging.
    private func processUsage(in persistence: HistoryPersistence,
                              fromBucket: Int, toBucket: Int,
                              timeout: TimeInterval = 1.0) -> [ProcessUsageSummary] {
        var loaded: [ProcessUsageSummary] = []
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let done = expectation(description: "processUsage")
            persistence.processUsage(fromBucket: fromBucket, toBucket: toBucket) { rows in
                loaded = rows
                done.fulfill()
            }
            wait(for: [done], timeout: timeout)
            if !loaded.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return loaded
    }

    // MARK: - Minute bucket

    func testMinuteBucketIsStableWithinALocalMinute() {
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let atStart = ProcessUsageAggregator.bucket(of: base)
        let atEnd = ProcessUsageAggregator.bucket(of: base.addingTimeInterval(59))
        let nextMinute = ProcessUsageAggregator.bucket(of: base.addingTimeInterval(60))

        XCTAssertEqual(atStart, atEnd)
        XCTAssertEqual(nextMinute, atStart + 1)
    }

    // MARK: - Accumulation

    func testSameNameProcessesMergeAndBytesAreRateTimesInterval() throws {
        let persistence = try makePersistence()
        let aggregator = ProcessUsageAggregator { persistence }
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let bucket = ProcessUsageAggregator.bucket(of: base)

        // Every pid's *first* frame is dropped (nettop reports it as
        // cumulative-since-launch), so each pid needs a second frame.
        aggregator.feed(entities: [entity(1, "Helper", 1000, 100)], interval: 2, now: base)
        aggregator.feed(entities: [entity(1, "Helper", 1000, 100)], interval: 2, now: base.addingTimeInterval(10))
        aggregator.feed(entities: [entity(2, "helper", 500, 50)], interval: 2, now: base.addingTimeInterval(20))
        aggregator.feed(entities: [entity(2, "helper", 500, 50)], interval: 2, now: base.addingTimeInterval(30))
        // Crossing into the next minute flushes the accumulated one.
        aggregator.feed(entities: [], interval: 2, now: base.addingTimeInterval(60))

        let rows = processUsage(in: persistence, fromBucket: bucket, toBucket: bucket + 1)
        XCTAssertEqual(rows.count, 1, "same-name pids and case variants are one row")
        XCTAssertEqual(rows.first?.name, "Helper", "the first-seen spelling is kept")
        XCTAssertEqual(rows.first?.inBytes, (1000 + 500) * 2, "bytes = Σ(rate) × interval")
        XCTAssertEqual(rows.first?.outBytes, (100 + 50) * 2)
    }

    func testZeroTrafficProcessesAreNotStored() throws {
        let persistence = try makePersistence()
        let aggregator = ProcessUsageAggregator { persistence }
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let bucket = ProcessUsageAggregator.bucket(of: base)

        aggregator.feed(entities: [entity(1, "idle", 0, 0)], interval: 2, now: base)
        aggregator.feed(entities: [entity(1, "idle", 0, 0)], interval: 2, now: base.addingTimeInterval(5))
        aggregator.feed(entities: [entity(2, "busy", 10, 0)], interval: 2, now: base.addingTimeInterval(10))
        aggregator.feed(entities: [entity(2, "busy", 10, 0)], interval: 2, now: base.addingTimeInterval(15))
        aggregator.feed(entities: [], interval: 2, now: base.addingTimeInterval(60))

        let rows = processUsage(in: persistence, fromBucket: bucket, toBucket: bucket + 1)
        XCTAssertEqual(rows.map(\.name), ["busy"], "a zero-traffic process must not create a row")
        XCTAssertEqual(rows.first?.inBytes, 20)
    }

    /// Regression: the accumulator must be cleared by a flush. Leaving it
    /// intact turned every later minute into "everything since launch" — the
    /// reported "results far too large" bug.
    func testAFlushedMinuteIsNotReAccumulatedLater() throws {
        let persistence = try makePersistence()
        let aggregator = ProcessUsageAggregator { persistence }
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let bucket = ProcessUsageAggregator.bucket(of: base)

        aggregator.feed(entities: [entity(1, "Helper", 1000, 100)], interval: 2, now: base)
        aggregator.feed(entities: [entity(1, "Helper", 1000, 100)], interval: 2, now: base.addingTimeInterval(10))
        // Rollover into minute 1 flushes minute 0.
        aggregator.feed(entities: [], interval: 2, now: base.addingTimeInterval(60))
        // Rollover into minute 2 flushes minute 1, which accumulated nothing.
        aggregator.feed(entities: [], interval: 2, now: base.addingTimeInterval(120))

        let minute0 = processUsage(in: persistence, fromBucket: bucket, toBucket: bucket + 1)
        XCTAssertEqual(minute0.count, 1)
        XCTAssertEqual(minute0.first?.inBytes, 2000, "minute 0 holds exactly its own two frames")

        let minute1 = processUsage(in: persistence, fromBucket: bucket + 1, toBucket: bucket + 2,
                                   timeout: 0.4)
        XCTAssertTrue(minute1.isEmpty, "minute 0 must not be written again into minute 1")
    }

    func testRangeQueryIsInclusiveStartExclusiveEnd() throws {
        let persistence = try makePersistence()
        let aggregator = ProcessUsageAggregator { persistence }
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let bucket = ProcessUsageAggregator.bucket(of: base)

        aggregator.feed(entities: [entity(1, "alpha", 100, 10)], interval: 2, now: base)
        aggregator.feed(entities: [entity(1, "alpha", 100, 10)], interval: 2, now: base.addingTimeInterval(10))
        // Rollover flushes alpha into minute 0, then bravo accumulates in 1.
        aggregator.feed(entities: [entity(2, "bravo", 200, 20)], interval: 2, now: base.addingTimeInterval(60))
        aggregator.feed(entities: [entity(2, "bravo", 200, 20)], interval: 2, now: base.addingTimeInterval(70))
        aggregator.feed(entities: [], interval: 2, now: base.addingTimeInterval(120))

        let onlyMinute0 = processUsage(in: persistence, fromBucket: bucket, toBucket: bucket + 1)
        XCTAssertEqual(onlyMinute0.map(\.name), ["alpha"])
    }

    // MARK: - Sort modes (shared with the App-usage tab)

    func testSortModes() {
        let rows = [
            ProcessUsageSummary(name: "zeta",  inBytes: 100, outBytes: 900),   // total 1000
            ProcessUsageSummary(name: "Alpha", inBytes: 800, outBytes: 100),   // total  900
            ProcessUsageSummary(name: "beta",  inBytes: 400, outBytes: 700),   // total 1100
        ]

        XCTAssertEqual(ProcessUsageModel.sort(rows: rows, mode: .name).map(\.name),
                       ["Alpha", "beta", "zeta"])
        XCTAssertEqual(ProcessUsageModel.sort(rows: rows, mode: .todayDownload).map(\.name),
                       ["Alpha", "beta", "zeta"])
        XCTAssertEqual(ProcessUsageModel.sort(rows: rows, mode: .todayUpload).map(\.name),
                       ["zeta", "beta", "Alpha"])
        XCTAssertEqual(ProcessUsageModel.sort(rows: rows, mode: .todayTotal).map(\.name),
                       ["beta", "zeta", "Alpha"])
    }

    func testSortingAnEmptyListIsAnEmptyList() {
        for mode in ListSortMode.allCases {
            XCTAssertTrue(ProcessUsageModel.sort(rows: [], mode: mode).isEmpty, "mode=\(mode)")
        }
    }
}
