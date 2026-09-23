//
//  HistoryPersistenceQueryTests.swift
//  FlowTraceTests
//
//  L2-1 ~ L2-10：补齐 HistoryPersistence 的只读查询 API。
//  这些方法在上轮测试中**从未被调用过**（上轮只覆盖了 recent / summary /
//  processUsage / interfaceMinuteHeatmap / alertRecords）。
//

import XCTest
import SQLite3
@testable import FlowTrace

final class HistoryPersistenceQueryTests: TempDatabaseTestCase {

    /// 固定基准时刻，避免用例受运行时刻影响。
    private let base = Date(timeIntervalSince1970: 1_788_516_000)

    private func flushRow(_ bucket: Int, _ name: String, inB: Int, outB: Int) -> ProcessUsageFlushRow {
        ProcessUsageFlushRow(minuteBucket: bucket, name: name,
                             nameKey: name.lowercased(), inBytes: inB, outBytes: outB)
    }

    /// 给异步写留出时间（写路径全部 `queue.async`）。
    private func drainWrites() {
        Thread.sleep(forTimeInterval: 0.4)
    }

    // MARK: - L2-1 / L2-2  usageBytes

    func testUsageBytesSumsHalfOpenRange() {
        let p = makePersistence()
        let b = ProcessUsageAggregator.bucket(of: base)
        p.appendProcessUsage([
            flushRow(b,     "a", inB: 100, outB: 10),
            flushRow(b + 1, "a", inB: 200, outB: 20),
            flushRow(b + 2, "a", inB: 400, outB: 40),   // 落在区间外
        ])
        drainWrites()

        let usage = awaitValue { p.usageBytes(fromBucket: b, toBucket: b + 2, completion: $0) }
        // 半开区间 [b, b+2)：含 b、b+1，不含 b+2
        XCTAssertEqual(usage?.inBytes, 300)
        XCTAssertEqual(usage?.outBytes, 30)
        XCTAssertEqual(usage?.total, 330)
    }

    func testUsageBytesOnEmptyRangeIsZero() {
        let p = makePersistence()
        let b = ProcessUsageAggregator.bucket(of: base)
        p.appendProcessUsage([flushRow(b, "a", inB: 100, outB: 10)])
        drainWrites()

        // 查一个完全没有数据、且 from == to 的空区间
        let usage = awaitValue { p.usageBytes(fromBucket: b + 10_000, toBucket: b + 10_000, completion: $0) }
        XCTAssertEqual(usage?.inBytes, 0)
        XCTAssertEqual(usage?.outBytes, 0)
    }

    // MARK: - L2-3 / L2-4  historyUsageBytes

    func testHistoryUsageBytesSumsHalfOpenRange() {
        let p = makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        p.append(HistoryRow(ts: nowMs - 3000, inBytesPerSec: 1000, outBytesPerSec: 100))
        p.append(HistoryRow(ts: nowMs - 2000, inBytesPerSec: 2000, outBytesPerSec: 200))
        p.append(HistoryRow(ts: nowMs - 1000, inBytesPerSec: 4000, outBytesPerSec: 400))  // 区间外
        drainWrites()

        let r = awaitValue { p.historyUsageBytes(fromMs: nowMs - 3000, toMs: nowMs - 1000, completion: $0) }
        XCTAssertEqual(r?.in, 3000)   // 1000 + 2000
        XCTAssertEqual(r?.out, 300)
    }

    func testHistoryUsageBytesWithReversedRangeIsZero() {
        let p = makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        p.append(HistoryRow(ts: nowMs, inBytesPerSec: 1000, outBytesPerSec: 100))
        drainWrites()

        // to < from：SQL 的 ts >= from AND ts < to 恒假
        let r = awaitValue { p.historyUsageBytes(fromMs: nowMs + 60_000, toMs: nowMs, completion: $0) }
        XCTAssertEqual(r?.in, 0)
        XCTAssertEqual(r?.out, 0)
    }

    // MARK: - L2-5  todayProcessTotals

    func testTodayProcessTotalsGroupsByLowercasedName() {
        let p = makePersistence()
        let b = ProcessUsageAggregator.bucket(of: base)
        p.appendProcessUsage([
            flushRow(b,     "Chrome", inB: 100, outB: 10),
            flushRow(b + 1, "Chrome", inB: 200, outB: 20),   // 同 name_key 跨桶
            flushRow(b + 1, "Safari", inB: 500, outB: 50),
            flushRow(b - 5, "Old",    inB: 999, outB: 99),   // 起点之前，应被排除
        ])
        drainWrites()

        let totals = awaitValue { p.todayProcessTotals(fromBucket: b, completion: $0) }
        XCTAssertEqual(totals?["chrome"]?.in, 300, "同名跨桶必须合并")
        XCTAssertEqual(totals?["chrome"]?.out, 30)
        XCTAssertEqual(totals?["safari"]?.in, 500)
        XCTAssertNil(totals?["old"], "起点之前的行不得计入")
    }

    // MARK: - L2-6  dailyProcessTotals

    func testDailyProcessTotalsGroupsByLocalDay() {
        let p = makePersistence()
        // 取一个本地日序数，保证 day0 / day1 落在不同自然日
        let day0 = ProcessUsageAggregator.bucket(of: base) / 1440
        let d0 = day0 * 1440 + 10          // day0 的某一分钟
        let d1 = (day0 + 1) * 1440 + 10    // day0+1 的某一分钟
        p.appendProcessUsage([
            flushRow(d0,     "Chrome", inB: 100, outB: 10),
            flushRow(d0 + 1, "Chrome", inB: 200, outB: 20),   // 同一自然日的另一分钟
            flushRow(d1,     "Chrome", inB: 700, outB: 70),
        ])
        drainWrites()

        let totals = awaitValue {
            p.dailyProcessTotals(fromBucket: d0, toBucket: d1 + 1440, completion: $0)
        }
        let perDay = totals?["chrome"]
        XCTAssertEqual(perDay?[day0]?.in, 300, "同一自然日的多分钟必须合并")
        XCTAssertEqual(perDay?[day0 + 1]?.in, 700)
    }

    // MARK: - L2-7  countRange

    func testCountRangeMatchesAllFourTables() {
        let p = makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let b = ProcessUsageAggregator.bucket(of: base)

        p.append(HistoryRow(ts: nowMs, inBytesPerSec: 1, outBytesPerSec: 1))                       // history 1
        p.appendInterface([InterfaceHistoryRow(ts: nowMs, category: "Wi-Fi",
                                               inBytesPerSec: 1, outBytesPerSec: 1)])              // interface_history 1
        p.appendProcessUsage([flushRow(b, "a", inB: 1, outB: 1),
                              flushRow(b + 1, "a", inB: 1, outB: 1)])                             // process_usage 2
        p.appendInterfaceMinute([(minuteBucket: b, category: "Wi-Fi", inBytes: 1, outBytes: 1)])   // interface_minute 1
        drainWrites()

        let fromMs = nowMs - 60_000, toMs = nowMs + 60_000
        let count = awaitValue { p.countRange(fromMs: fromMs, toMs: toMs,
                                              fromBucket: b, toBucket: b + 2, completion: $0) }
        XCTAssertEqual(count, 5, "4 张表合计 1+1+2+1")

        // 与 deleteRange 的返回值应一致
        let deleted = awaitValue { p.deleteRange(fromMs: fromMs, toMs: toMs,
                                                 fromBucket: b, toBucket: b + 2, completion: $0) }
        XCTAssertEqual(deleted, count, "countRange 与 deleteRange 必须对同一区间给出同一行数")
    }

    // MARK: - L2-8  expiredRowCount

    func testExpiredRowCountMatchesPruneExpired() {
        let p = makePersistence()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let oldMs = nowMs - 10 * 86_400_000        // 10 天前
        let b = ProcessUsageAggregator.bucket(of: Date())

        p.append(HistoryRow(ts: oldMs, inBytesPerSec: 1, outBytesPerSec: 1))        // 过期
        p.append(HistoryRow(ts: nowMs, inBytesPerSec: 1, outBytesPerSec: 1))        // 未过期
        p.appendInterface([InterfaceHistoryRow(ts: oldMs, category: "Wi-Fi",
                                               inBytesPerSec: 1, outBytesPerSec: 1)]) // 过期
        p.appendProcessUsage([flushRow(b - 10 * 1440, "old", inB: 1, outB: 1),     // 过期
                              flushRow(b, "new", inB: 1, outB: 1)])                 // 未过期
        drainWrites()

        let cutoffMs = nowMs - 86_400_000            // 1 天前
        let cutoffBucket = b - 1440

        let expired = awaitValue { p.expiredRowCount(cutoffMs: cutoffMs,
                                                    cutoffBucket: cutoffBucket, completion: $0) }
        // process_alert 为空，故过期行 = history1 + interface_history1 + process_usage1 = 3
        XCTAssertEqual(expired, 3)

        let deleted = awaitValue { p.pruneExpired(cutoffMs: cutoffMs,
                                                  cutoffBucket: cutoffBucket, completion: $0) }
        XCTAssertEqual(deleted, expired,
                       "expiredRowCount 预告的行数必须等于 pruneExpired 实际删除的行数")
    }

    // MARK: - L2-9  CSV 导出的读路径

    func testExportProcessUsageReturnsRowsOrderedByBucket() {
        let p = makePersistence()
        let b = ProcessUsageAggregator.bucket(of: base)
        p.appendProcessUsage([
            flushRow(b + 1, "zebra", inB: 20, outB: 2),
            flushRow(b,     "alpha", inB: 10, outB: 1),
        ])
        drainWrites()

        let rows = awaitValue { p.exportProcessUsage(fromBucket: b, toBucket: b + 2, completion: $0) }
        XCTAssertEqual(rows?.count, 2)
        // ORDER BY minute_bucket, name
        XCTAssertEqual(rows?.map(\.name), ["alpha", "zebra"])
        XCTAssertEqual(rows?.first?.inBytes, 10)
        // time 必须由本地分钟序号还原，而非 1970
        let expected = HistoryPersistence.date(fromLocalMinuteBucket: b)
        XCTAssertEqual(rows!.first!.time.timeIntervalSince(expected), 0, accuracy: 1)
    }

    func testExportInterfaceMinuteReturnsRows() {
        let p = makePersistence()
        let b = ProcessUsageAggregator.bucket(of: base)
        p.appendInterfaceMinute([
            (minuteBucket: b, category: "Wi-Fi", inBytes: 111, outBytes: 22),
            (minuteBucket: b + 1, category: "Wired", inBytes: 333, outBytes: 44),
        ])
        drainWrites()

        let rows = awaitValue { p.exportInterfaceMinute(fromBucket: b, toBucket: b + 2, completion: $0) }
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?.map(\.category), ["Wi-Fi", "Wired"])
        XCTAssertEqual(rows?.first?.inBytes, 111)
    }

    // MARK: - L2-10  分钟序号 ↔ Date 互逆

    func testLocalMinuteBucketDateRoundTrip() {
        for bucket in [0, 1, 29_834_947, 30_000_000] {
            let date = HistoryPersistence.date(fromLocalMinuteBucket: bucket)
            let back = ProcessUsageAggregator.bucket(of: date)
            XCTAssertEqual(back, bucket,
                           "bucket=\(bucket) → Date → bucket 必须回到原值（date 是 bucket 的精确逆）")
        }
    }
}
