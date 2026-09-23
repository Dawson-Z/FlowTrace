//
//  InterfaceMinuteAggregatorTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：InterfaceMinuteAggregator 端到端（4 项）
//  feed → 跨分钟 flush → 临时 DB 回读；reset 丢弃在途分钟。
//

import XCTest
import SQLite3
@testable import FlowTrace

final class InterfaceMinuteAggregatorTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        tempURLs = []
        super.tearDown()
    }

    private func makePersistence() throws -> HistoryPersistence {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-ifmin-\(UUID().uuidString).sqlite3")
        tempURLs.append(url)
        return try XCTUnwrap(HistoryPersistence(dbURL: url, retentionSeconds: 3600))
    }

    private func snapshot(wifiIn: Int, wifiOut: Int) -> InterfaceSnapshot {
        var s = InterfaceSnapshot()
        s.bytesIn[.wifi] = wifiIn
        s.bytesOut[.wifi] = wifiOut
        return s
    }

    // K24: 跨分钟 flush 后数据落库
    func testFlushOnMinuteRollover() throws {
        let p = try makePersistence()
        let agg = InterfaceMinuteAggregator()
        let base = Date(timeIntervalSince1970: 1_788_516_000)

        agg.feed(snapshot(wifiIn: 100, wifiOut: 50), now: base, persistence: p)
        agg.feed(snapshot(wifiIn: 200, wifiOut: 100), now: base.addingTimeInterval(30), persistence: p)
        // 跨分钟触发 flush
        agg.feed(snapshot(wifiIn: 0, wifiOut: 0), now: base.addingTimeInterval(60), persistence: p)
        Thread.sleep(forTimeInterval: 0.4)

        var rows: [(bucket: Int, category: String, inB: Int, outB: Int)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT minute_bucket, category, in_bytes, out_bytes FROM interface_minute;"
        XCTAssertEqual(sqlite3_prepare_v2(p.db, sql, -1, &stmt, nil), SQLITE_OK)
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((Int(sqlite3_column_int64(stmt, 0)),
                         String(cString: sqlite3_column_text(stmt, 1)),
                         Int(sqlite3_column_int64(stmt, 2)),
                         Int(sqlite3_column_int64(stmt, 3))))
        }
        XCTAssertEqual(rows.count, 1, "one flush = one row")
        XCTAssertEqual(rows.first?.category, "Wi-Fi")
        XCTAssertEqual(rows.first?.inB, 300, "100 + 200")
        XCTAssertEqual(rows.first?.outB, 150, "50 + 100")
    }

    // K25: flush 后不重复累加（与 ProcessUsageAggregator 同一回归）
    func testFlushedMinuteNotReaccumulated() throws {
        let p = try makePersistence()
        let agg = InterfaceMinuteAggregator()
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let bucket = InterfaceMinuteAggregator.minuteBucket(base)

        agg.feed(snapshot(wifiIn: 100, wifiOut: 50), now: base, persistence: p)
        agg.feed(snapshot(wifiIn: 0, wifiOut: 0), now: base.addingTimeInterval(60), persistence: p)
        agg.feed(snapshot(wifiIn: 0, wifiOut: 0), now: base.addingTimeInterval(120), persistence: p)
        Thread.sleep(forTimeInterval: 0.4)

        var count = 0
        var total = 0
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*), COALESCE(SUM(in_bytes),0) FROM interface_minute WHERE minute_bucket = ?;"
        XCTAssertEqual(sqlite3_prepare_v2(p.db, sql, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_int64(stmt, 1, Int64(bucket))
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(stmt, 0))
            total = Int(sqlite3_column_int64(stmt, 1))
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(total, 100, "minute must hold only its own frames")
    }

    // K26: minuteBucket 与 ProcessUsageAggregator.bucket 同一约定
    func testMinuteBucketMatchesProcessUsageAggregator() {
        let d = Date()
        XCTAssertEqual(InterfaceMinuteAggregator.minuteBucket(d),
                       ProcessUsageAggregator.bucket(of: d),
                       "both minute tables must align on bucket boundaries")
    }

    // K27: reset 丢弃在途分钟（不清空 DB，只清内存）
    func testResetDropsInFlightMinute() throws {
        let p = try makePersistence()
        let agg = InterfaceMinuteAggregator()
        let base = Date(timeIntervalSince1970: 1_788_516_000)

        agg.feed(snapshot(wifiIn: 500, wifiOut: 0), now: base, persistence: p)
        agg.reset()
        // reset 后同一分钟再次 feed：旧累积应已丢弃
        agg.feed(snapshot(wifiIn: 10, wifiOut: 0), now: base.addingTimeInterval(5), persistence: p)
        agg.feed(snapshot(wifiIn: 0, wifiOut: 0), now: base.addingTimeInterval(60), persistence: p)
        Thread.sleep(forTimeInterval: 0.4)

        var total = -1
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COALESCE(SUM(in_bytes), -1) FROM interface_minute;"
        XCTAssertEqual(sqlite3_prepare_v2(p.db, sql, -1, &stmt, nil), SQLITE_OK)
        if sqlite3_step(stmt) == SQLITE_ROW {
            total = Int(sqlite3_column_int64(stmt, 0))
        }
        XCTAssertEqual(total, 10, "pre-reset accumulation (500) must be dropped")
    }
}
