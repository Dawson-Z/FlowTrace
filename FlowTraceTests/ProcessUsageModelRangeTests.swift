//
//  ProcessUsageModelRangeTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：ProcessUsageModel.rangeBuckets / HistoryHeatmapModel.date(forDay:)（3 项）
//

import XCTest
@testable import FlowTrace

final class ProcessUsageModelRangeTests: XCTestCase {

    // K21: rangeBuckets — today ⊂ 7d ⊂ 30d（本地分钟序数）
    func testRangeBucketOrdering() {
        let from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let to = Date()
        let today = ProcessUsageModel.rangeBuckets(range: .today, customFrom: from, customTo: to)
        let d7 = ProcessUsageModel.rangeBuckets(range: .last7Days, customFrom: from, customTo: to)
        let d30 = ProcessUsageModel.rangeBuckets(range: .last30Days, customFrom: from, customTo: to)

        XCTAssertLessThan(d30.from, d7.from)
        XCTAssertLessThan(d7.from, today.from)
        // 三者的 to 都是明天零点，应相同
        XCTAssertEqual(today.to, d7.to)
        XCTAssertEqual(d7.to, d30.to)
        // 7 天 = 7 × 1440 分钟
        XCTAssertEqual(d7.to - d7.from, 7 * 1440)
        XCTAssertEqual(d30.to - d30.from, 30 * 1440)
    }

    // K22: rangeBuckets — custom 跨度
    func testRangeBucketCustom() {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        let to = cal.startOfDay(for: Date())
        let b = ProcessUsageModel.rangeBuckets(range: .custom, customFrom: from, customTo: to)
        XCTAssertEqual(b.to - b.from, 4 * 1440, "custom to-day is inclusive (+1 day)")
    }

    // K23: HistoryHeatmapModel.date(forDay:) 往返（本地 day 序数 → Date → 本地 day 序数）
    func testHeatmapDateForDayRoundTrip() {
        let model = HistoryHeatmapModel()
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        // date(forDay:) 的 day 是本地日序数（与 minute_bucket 同族约定）
        let todayOrdinal = Int((Date().timeIntervalSince1970 + tz) / 86400)
        let date = model.date(forDay: todayOrdinal)
        let back = Int((date.timeIntervalSince1970 + tz) / 86400)
        XCTAssertEqual(back, todayOrdinal)
    }
}
