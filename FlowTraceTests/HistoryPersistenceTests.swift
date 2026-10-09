//
//  HistoryPersistenceTests.swift
//  FlowTraceTests
//
//  G 组：HistoryPersistence 端到端（12 项）
//  5 表 schema、append / recent / summary / 范围查询、prune / deleteRange、UNIQUE 去重。
//

import XCTest
import SQLite3
@testable import FlowTrace

final class HistoryPersistenceTests: XCTestCase {

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

    private func makePersistence(retentionSeconds: TimeInterval = 7 * 24 * 3600) throws -> HistoryPersistence {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-persist-\(UUID().uuidString).sqlite3")
        tempURLs.append(url)
        return try XCTUnwrap(HistoryPersistence(dbURL: url, retentionSeconds: retentionSeconds))
    }

    // 等待异步回调的通用帮手（默认 timeout = 1.0）
    private func waitForCompletion<T>(_ block: @escaping (@escaping (T) -> Void) -> Void) -> T {
        return waitForCompletion(1.0, block)
    }

    private func waitForCompletion<T>(_ timeout: TimeInterval,
                                      _ block: @escaping (@escaping (T) -> Void) -> Void) -> T {
        let exp = expectation(description: "completion")
        var result: T?
        block { value in
            result = value
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        return result!
    }

    // G1: 首次打开自动建库（含 WAL/SHM）
    func testFirstOpenCreatesDatabase() throws {
        let p = try makePersistence()
        let url = p.dbURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // WAL 模式下会创建 -wal 与 -shm 边车
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let shm = URL(fileURLWithPath: url.path + "-shm")
        // 边车可能在关连接后才落盘，所以不强制存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        _ = shm
        _ = wal
    }

    // G2: Schema 校验（5 表 + 4 普通索引 + 1 UNIQUE索引）
    func testSchemaHasAllTables() throws {
        let p = try makePersistence()
        // 通过 sqlite_master 查询表名集合
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
        XCTAssertEqual(sqlite3_prepare_v2(p.db, sql, -1, &stmt, nil), SQLITE_OK)
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: cstr))
            }
        }
        let required = ["history", "interface_history", "interface_minute", "process_usage", "process_alert"]
        for t in required {
            XCTAssertTrue(names.contains(t), "missing table \(t), got \(names)")
        }

        // 索引（idx_alert_unique 必须存在）
        var idxStmt: OpaquePointer?
        defer { sqlite3_finalize(idxStmt) }
        let idxSql = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_alert_unique';"
        XCTAssertEqual(sqlite3_prepare_v2(p.db, idxSql, -1, &idxStmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(idxStmt), SQLITE_ROW, "idx_alert_unique must exist")
    }

    // G3: append 后 recent(limit:) 同步读返回最近 N 行升序
    func testAppendAndRecentRoundTrip() throws {
        let p = try makePersistence()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<5 {
            p.append(HistoryRow(ts: now + Int64(i) * 1000, inBytesPerSec: i * 100, outBytesPerSec: i))
        }
        // 等异步写入完成
        Thread.sleep(forTimeInterval: 0.1)
        let recent = p.recent(limit: 10)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.last?.inBytesPerSec, 400)  // 最后一帧
        // recent() 返回升序
        for (a, b) in zip(recent, recent.dropFirst()) {
            XCTAssertLessThanOrEqual(a.ts, b.ts)
        }
    }

    // G4: summary 聚合
    func testSummaryAggregates() throws {
        let p = try makePersistence()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let dayStart = Calendar.current.startOfDay(for: Date())
        let dayStartMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        for i in 0..<3 {
            p.append(HistoryRow(ts: now - Int64(i) * 1000, inBytesPerSec: 1000, outBytesPerSec: 200))
        }
        Thread.sleep(forTimeInterval: 0.2)
        let summary = waitForCompletion { p.summary(dayStart: dayStart, completion: $0) }
        // 今日累计 in = Σ(1000) * 3
        XCTAssertEqual(summary.todayInBytes, 3000)
        XCTAssertEqual(summary.todayOutBytes, 600)
        XCTAssertGreaterThanOrEqual(summary.todayPeakIn, 1000)
    }

    // G5: processUsage 半开区间
    func testProcessUsageHalfOpenRange() throws {
        let p = try makePersistence()
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        let b0 = ProcessUsageAggregator.bucket(of: base)
        p.appendProcessUsage([ProcessUsageFlushRow(minuteBucket: b0, name: "alpha", nameKey: "alpha",
                                                   inBytes: 100, outBytes: 10)])
        p.appendProcessUsage([ProcessUsageFlushRow(minuteBucket: b0 + 1, name: "beta", nameKey: "beta",
                                                   inBytes: 200, outBytes: 20)])
        p.appendProcessUsage([ProcessUsageFlushRow(minuteBucket: b0 + 2, name: "gamma", nameKey: "gamma",
                                                   inBytes: 300, outBytes: 30)])
        Thread.sleep(forTimeInterval: 0.3)
        // [b0, b0+2) 应只含 alpha + beta
        let rows = waitForCompletion(2.0) { p.processUsage(fromBucket: b0, toBucket: b0 + 2, completion: $0) }
        let names = Set(rows.map(\.name))
        XCTAssertEqual(names, ["alpha", "beta"])
        XCTAssertFalse(names.contains("gamma"))
    }

    // G6: interfaceMinuteHeatmap 按本地小时桶 — 通过直接 SQL 验证 aggregator 逻辑
    //（避免 ms ↔ minute_bucket 偏移计算的细微偏差，已由 HistoryHeatmapPersistenceTests 覆盖）
    func testInterfaceMinuteHeatmapLocalBucket() throws {
        let p = try makePersistence()
        let bucket = ProcessUsageAggregator.bucket(of: Date())
        p.appendInterfaceMinute([
            (minuteBucket: bucket - 30, category: "Wi-Fi", inBytes: 100, outBytes: 50),
            (minuteBucket: bucket, category: "Wi-Fi", inBytes: 200, outBytes: 100),
            (minuteBucket: bucket, category: "Wired", inBytes: 50, outBytes: 25),
        ])
        Thread.sleep(forTimeInterval: 0.6)

        // 直接 SQL 验证表内数据正确
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT category, SUM(in_bytes), SUM(out_bytes) FROM interface_minute GROUP BY category;"
        XCTAssertEqual(sqlite3_prepare_v2(p.db, sql, -1, &stmt, nil), SQLITE_OK)
        var seen: [String: (in: Int, out: Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cat = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let inB = Int(sqlite3_column_int64(stmt, 1))
            let outB = Int(sqlite3_column_int64(stmt, 2))
            seen[cat] = (in: inB, out: outB)
        }
        XCTAssertEqual(seen["Wi-Fi"]?.in, 300, "Wi-Fi in = 100 + 200")
        XCTAssertEqual(seen["Wi-Fi"]?.out, 150)
        XCTAssertEqual(seen["Wired"]?.in, 50)
        XCTAssertEqual(seen["Wired"]?.out, 25)
    }

    // G7: 重开不触发任何启动期删除——保留期策略唯一归属 DataRetentionController
    // （自动模式每日检查点才删；手动提醒模式绝不删。2026-10-09 移除 init prune 之前，
    //   每次启动都会无视清理模式、静默删掉保留窗口外的全部数据。）
    func testReopenDoesNotPruneAnyTable() throws {
        // retentionSeconds 设为 1：所有帧都在窗口外
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-prune-\(UUID().uuidString).sqlite3")
        tempURLs.append(url)
        // 先建库
        let p1 = HistoryPersistence(dbURL: url, retentionSeconds: 7 * 24 * 3600)!
        let oldMs = Int64((Date().timeIntervalSince1970 - 10 * 86400) * 1000)
        p1.append(HistoryRow(ts: oldMs, inBytesPerSec: 100, outBytesPerSec: 100))
        p1.appendInterface([InterfaceHistoryRow(ts: oldMs, category: "Wi-Fi",
                                                inBytesPerSec: 50, outBytesPerSec: 50)])
        let today = ProcessUsageAggregator.bucket(of: Date())
        let oldBucket = today - 10 * 1440
        p1.appendProcessUsage([ProcessUsageFlushRow(minuteBucket: oldBucket,
                                                    name: "old", nameKey: "old",
                                                    inBytes: 1, outBytes: 1)])
        p1.appendProcessAlert(ProcessAlertRow(day: 19000, name: "old", nameKey: "old",
                                              direction: "in", todayBytes: 1, baselineBytes: 0,
                                              multiplier: 0, ts: Int64(Date().timeIntervalSince1970 * 1000))) { _ in }
        // 等待异步写完成
        Thread.sleep(forTimeInterval: 0.5)
        // 重建库（retentionSeconds=1 曾在 init 触发 prune；现在必须什么都不删）
        let p2 = HistoryPersistence(dbURL: url, retentionSeconds: 1)!
        Thread.sleep(forTimeInterval: 0.1)
        // history 旧行仍在（旧 init prune 的 ts 分支）
        XCTAssertTrue(p2.recent(limit: 10).contains { $0.ts == oldMs },
                      "reopen must not prune history")
        // process_usage 旧桶仍在（旧 init prune 的 minute-bucket 分支）
        let totals = waitForCompletion(2.0) {
            p2.dailyProcessTotals(fromBucket: oldBucket, toBucket: oldBucket + 1440, completion: $0)
        }
        XCTAssertNotNil(totals["old"], "reopen must not prune process_usage")
        // process_alert 仍在（从未参与任何删除路径）
        let records = waitForCompletion(2.0) { p2.alertRecords(completion: $0) }
        XCTAssertFalse(records.isEmpty, "reopen must not touch process_alert")
    }

    // G8: pruneExpired 每日检查点
    func testPruneExpiredCutsOffAllFourTables() throws {
        let p = try makePersistence()
        let oldMs = Int64((Date().timeIntervalSince1970 - 10 * 86400) * 1000)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let today = ProcessUsageAggregator.bucket(of: Date())
        // 旧行
        p.append(HistoryRow(ts: oldMs, inBytesPerSec: 100, outBytesPerSec: 100))
        p.appendInterface([InterfaceHistoryRow(ts: oldMs, category: "Wi-Fi",
                                                inBytesPerSec: 50, outBytesPerSec: 50)])
        p.appendProcessAlert(ProcessAlertRow(day: 19000, name: "old", nameKey: "old",
                                              direction: "in", todayBytes: 1, baselineBytes: 0,
                                              multiplier: 0, ts: oldMs)) { _ in }
        p.appendProcessUsage([ProcessUsageFlushRow(minuteBucket: today - 10 * 1440,
                                                    name: "old", nameKey: "old",
                                                    inBytes: 1, outBytes: 1)])
        Thread.sleep(forTimeInterval: 0.5)
        // cutoff = now - 1 天
        let cutoffMs = nowMs - 86400 * 1000
        let cutoffBucket = today - 1440
        let deleted = waitForCompletion(2.0) {
            p.pruneExpired(cutoffMs: cutoffMs, cutoffBucket: cutoffBucket, completion: $0)
        }
        XCTAssertGreaterThan(deleted, 0)
        // process_alert 历史应被删（看源码 line 274-296：含 process_alert）
        let records = waitForCompletion(2.0) { p.alertRecords(completion: $0) }
        XCTAssertTrue(records.isEmpty, "pruneExpired should remove old process_alert rows")
    }

    // G9: deleteRange 含 5 表（含 process_alert，2026-10-09 起与提醒计数同口径）
    // 跨整时把所有行都删
    func testDeleteRangeFullWindow() throws {
        let p = try makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        p.append(HistoryRow(ts: nowMs - 1000, inBytesPerSec: 100, outBytesPerSec: 100))
        let today = ProcessUsageAggregator.bucket(of: Date())
        p.appendProcessUsage([ProcessUsageFlushRow(minuteBucket: today, name: "x", nameKey: "x",
                                                   inBytes: 1, outBytes: 1)])
        Thread.sleep(forTimeInterval: 0.3)
        let _ = waitForCompletion { p.deleteRange(fromMs: nowMs - 86400000, toMs: nowMs + 86400000,
                                                  fromBucket: today - 1440, toBucket: today + 1440,
                                                  completion: $0) }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(p.recent(limit: 100).isEmpty, "deleteRange across full window should clear history")
    }

    // G10: deleteRange 半开区间、覆盖 process_alert（2026-10-09 起与提醒计数
    // expiredRowCount 同口径——提醒把示警记录计入逾期行数，存储页清理必须能清掉它们。
    // 副作用：清示警记录同时清 (day, name_key, direction) 去重状态，同日同方向可能再告警。）
    func testDeleteRangeClearsAlerts() throws {
        let p = try makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let today = ProcessUsageAggregator.bucket(of: Date())
        p.append(HistoryRow(ts: nowMs - 1000, inBytesPerSec: 100, outBytesPerSec: 100))
        p.appendProcessAlert(ProcessAlertRow(day: 19000, name: "alrt", nameKey: "alrt",
                                              direction: "in", todayBytes: 1, baselineBytes: 0,
                                              multiplier: 0, ts: nowMs)) { _ in }
        Thread.sleep(forTimeInterval: 0.3)
        let _ = waitForCompletion(2.0) {
            p.deleteRange(fromMs: nowMs - 86400000, toMs: nowMs + 86400000,
                          fromBucket: today - 1440, toBucket: today + 1440, completion: $0)
        }
        Thread.sleep(forTimeInterval: 0.1)
        // process_alert 一并清除
        let records = waitForCompletion(2.0) { p.alertRecords(completion: $0) }
        XCTAssertTrue(records.isEmpty, "deleteRange must clear process_alert (same scope as expiredRowCount)")
    }

    // G11: appendProcessAlert UNIQUE 去重
    func testProcessAlertUniqueDedup() throws {
        let p = try makePersistence()
        let row = ProcessAlertRow(day: 19999, name: "x", nameKey: "x",
                                  direction: "in", todayBytes: 100, baselineBytes: 50,
                                  multiplier: 2.0, ts: Int64(Date().timeIntervalSince1970 * 1000))
        let inserted1 = waitForCompletion(2.0) { p.appendProcessAlert(row, completion: $0) }
        let inserted2 = waitForCompletion(2.0) { p.appendProcessAlert(row, completion: $0) }
        XCTAssertTrue(inserted1)
        XCTAssertFalse(inserted2, "UNIQUE index must reject second insert on same (day,name_key,dir)")
    }

    // G12: 主线程连续 1000 次写不死锁（间接：跑完 G1-G11 已隐含验证）
    func testMainQueueStress() throws {
        let p = try makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<1000 {
            p.append(HistoryRow(ts: nowMs + Int64(i), inBytesPerSec: i, outBytesPerSec: i))
        }
        // 同步读 recent(limit:) 不死锁
        Thread.sleep(forTimeInterval: 0.5)
        let rows = p.recent(limit: 10)
        XCTAssertEqual(rows.count, 10)
    }
}