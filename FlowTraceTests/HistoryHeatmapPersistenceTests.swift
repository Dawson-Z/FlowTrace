//
//  HistoryHeatmapPersistenceTests.swift
//  FlowTraceTests
//
//  The history window's heatmap reads `interface_minute` through
//  `HistoryPersistence.interfaceMinuteHeatmap`, which sums each interface
//  category into local hour buckets (`minute_bucket / 60`). These tests write
//  rows into a real (temporary) database and read the aggregation back, so the
//  SQL itself is under test rather than a hand-written mirror of it.
//
//  Replaces `scripts/verify_history.swift`, whose aggregation and category
//  filter were re-implemented in Swift and could silently disagree with the
//  query.
//

import XCTest
@testable import FlowTrace

final class HistoryHeatmapPersistenceTests: XCTestCase {

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

    private func makePersistence() throws -> HistoryPersistence {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-heatmap-\(UUID().uuidString).sqlite3")
        tempURLs.append(url)
        return try XCTUnwrap(HistoryPersistence(dbURL: url, retentionSeconds: 3600))
    }

    /// Local minute ordinal for an instant, plus the ms window that maps onto
    /// exactly that minute — the same `(epochMs + tzMs) / 60_000` convention
    /// the writer and the query both use.
    private func minute(_ date: Date) -> (bucket: Int, fromMs: Int64, toMs: Int64) {
        let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let bucket = Int((ms + tzMs) / 60000)
        return (bucket,
                Int64(bucket) * 60000 - tzMs,
                Int64(bucket + 1) * 60000 - tzMs)
    }

    private func heatmap(_ persistence: HistoryPersistence,
                         fromMs: Int64, toMs: Int64,
                         categories: [String]) -> [HeatmapCell] {
        var cells: [HeatmapCell] = []
        let done = expectation(description: "interfaceMinuteHeatmap")
        persistence.interfaceMinuteHeatmap(fromMs: fromMs, toMs: toMs, categories: categories) { result in
            cells = result
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return cells
    }

    private var allCategories: [String] { InterfaceCategory.allCases.map(\.rawValue) }

    // MARK: - Bucket convention

    func testMinuteBucketMatchesTheLocalMinuteOrdinal() {
        let now = Date()
        let tzSeconds = TimeZone.current.secondsFromGMT()
        let expected = Int((now.timeIntervalSince1970 + Double(tzSeconds)) / 60)
        XCTAssertEqual(InterfaceMinuteAggregator.minuteBucket(now), expected)
    }

    // MARK: - Aggregation

    func testCategoriesAreSummedIntoLocalHourBuckets() throws {
        let persistence = try makePersistence()
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let hour0 = minute(base)
        // One hour later lands in the next hour bucket.
        let hour1 = minute(base.addingTimeInterval(3600))

        persistence.appendInterfaceMinute([
            (minuteBucket: hour0.bucket, category: "Wi-Fi",        inBytes: 1000, outBytes: 100),
            (minuteBucket: hour0.bucket, category: "Wi-Fi",        inBytes: 3000, outBytes: 300),
            (minuteBucket: hour0.bucket, category: "Wired",        inBytes: 2000, outBytes: 200),
            (minuteBucket: hour1.bucket, category: "Local Direct", inBytes: 9000, outBytes: 900),
            (minuteBucket: hour1.bucket, category: "Local Direct", inBytes: 1000, outBytes: 100),
        ])

        let cells = heatmap(persistence, fromMs: hour0.fromMs, toMs: hour1.toMs,
                            categories: allCategories)

        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].inBytes, 1000 + 3000 + 2000, "all categories of that hour, summed")
        XCTAssertEqual(cells[0].outBytes, 100 + 300 + 200)
        XCTAssertEqual(cells[1].inBytes, 9000 + 1000)
        XCTAssertEqual(cells[1].outBytes, 900 + 100)
        XCTAssertEqual(cells[1].day * 24 + cells[1].hour,
                       cells[0].day * 24 + cells[0].hour + 1,
                       "consecutive hours")
    }

    func testCategoryFilterExcludesTheOtherInterfaces() throws {
        let persistence = try makePersistence()
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let hour0 = minute(base)
        let hour1 = minute(base.addingTimeInterval(3600))

        persistence.appendInterfaceMinute([
            (minuteBucket: hour0.bucket, category: "Wi-Fi",        inBytes: 1000, outBytes: 100),
            (minuteBucket: hour0.bucket, category: "Wired",        inBytes: 2000, outBytes: 200),
            (minuteBucket: hour1.bucket, category: "Local Direct", inBytes: 9000, outBytes: 900),
        ])

        let wifiOnly = heatmap(persistence, fromMs: hour0.fromMs, toMs: hour1.toMs,
                               categories: ["Wi-Fi"])
        XCTAssertEqual(wifiOnly.count, 1)
        XCTAssertEqual(wifiOnly[0].inBytes, 1000, "the wired row must not leak into the Wi-Fi cell")
        XCTAssertEqual(wifiOnly[0].outBytes, 100)

        let localDirectOnly = heatmap(persistence, fromMs: hour0.fromMs, toMs: hour1.toMs,
                                      categories: ["Local Direct"])
        XCTAssertEqual(localDirectOnly.count, 1)
        XCTAssertEqual(localDirectOnly[0].inBytes, 9000)
    }

    // MARK: - Edges

    func testEmptyRangeYieldsNoCells() throws {
        let persistence = try makePersistence()
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let hour0 = minute(base)
        persistence.appendInterfaceMinute([
            (minuteBucket: hour0.bucket, category: "Wi-Fi", inBytes: 1000, outBytes: 100),
        ])

        // A window a day earlier than the only row.
        let cells = heatmap(persistence,
                            fromMs: hour0.fromMs - 86_400_000,
                            toMs: hour0.fromMs - 86_400_000 + 1,
                            categories: allCategories)
        XCTAssertTrue(cells.isEmpty)
    }

    func testNoCategorySelectedYieldsNoCells() throws {
        let persistence = try makePersistence()
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let hour0 = minute(base)
        persistence.appendInterfaceMinute([
            (minuteBucket: hour0.bucket, category: "Wi-Fi", inBytes: 1000, outBytes: 100),
        ])

        // The UI's "all off" state must read as an empty grid, never as "all".
        let cells = heatmap(persistence, fromMs: 0, toMs: hour0.toMs, categories: [])
        XCTAssertTrue(cells.isEmpty)
    }

    func testLocalMidnightSplitsIntoDifferentDayCells() throws {
        let persistence = try makePersistence()
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_788_516_000))
        let lastMinuteOfYesterday = minute(midnight.addingTimeInterval(-60))
        let firstMinuteOfToday = minute(midnight)

        persistence.appendInterfaceMinute([
            (minuteBucket: lastMinuteOfYesterday.bucket, category: "Wi-Fi", inBytes: 500, outBytes: 50),
            (minuteBucket: firstMinuteOfToday.bucket,    category: "Wi-Fi", inBytes: 700, outBytes: 70),
        ])

        let cells = heatmap(persistence,
                            fromMs: lastMinuteOfYesterday.fromMs,
                            toMs: firstMinuteOfToday.toMs,
                            categories: ["Wi-Fi"])

        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].hour, 23, "the minute before local midnight is hour 23")
        XCTAssertEqual(cells[1].hour, 0)
        XCTAssertEqual(cells[1].day, cells[0].day + 1, "and it belongs to the next local day")
        XCTAssertEqual(cells[1].inBytes, 700, "the two sides of midnight are separate cells")
    }
}
