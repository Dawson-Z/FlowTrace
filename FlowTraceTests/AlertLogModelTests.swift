//
//  AlertLogModelTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：AlertLogModel.sort 纯函数 + AlertRange.fromMs（4 项）
//

import XCTest
@testable import FlowTrace

final class AlertLogModelTests: XCTestCase {

    private func rec(_ name: String, daysAgo: Int = 0, isIn: Bool = true,
                     today: Int = 100, baseline: Int = 10, mult: Double = 10) -> AlertRecord {
        AlertRecord(
            date: Calendar.current.date(byAdding: .day, value: -daysAgo,
                                        to: Calendar.current.startOfDay(for: Date()))!,
            name: name, isIn: isIn,
            todayBytes: today, baselineBytes: baseline, multiplier: mult
        )
    }

    // K17: sort — 六种模式的基础序 + 名称 tie-break
    func testSortModes() {
        let rows = [
            rec("zeta", today: 100, baseline: 900, mult: 0.1),
            rec("Alpha", today: 800, baseline: 100, mult: 8),
            rec("beta",  today: 400, baseline: 700, mult: 0.5),
        ]

        // name：字典序
        XCTAssertEqual(AlertLogModel.sort(records: rows, mode: .name).map(\.name),
                       ["Alpha", "beta", "zeta"])
        // today：字节数降序
        XCTAssertEqual(AlertLogModel.sort(records: rows, mode: .today).map(\.name),
                       ["Alpha", "beta", "zeta"])
        // median：基线降序
        XCTAssertEqual(AlertLogModel.sort(records: rows, mode: .median).map(\.name),
                       ["zeta", "beta", "Alpha"])
        // factor：倍率降序，0.1 的落在最后
        XCTAssertEqual(AlertLogModel.sort(records: rows, mode: .factor).map(\.name),
                       ["Alpha", "beta", "zeta"])
    }

    // K18: sort — direction 模式：下载组在前、组内最新优先
    func testSortDirectionGroupsDownloadsFirst() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let rows = [
            AlertRecord(date: old, name: "upA", isIn: false, todayBytes: 1, baselineBytes: 0, multiplier: 0),
            AlertRecord(date: new, name: "downB", isIn: true, todayBytes: 1, baselineBytes: 0, multiplier: 0),
            AlertRecord(date: old, name: "downA", isIn: true, todayBytes: 1, baselineBytes: 0, multiplier: 0),
        ]
        let sorted = AlertLogModel.sort(records: rows, mode: .direction)
        // 下载组在前，组内 new > old
        XCTAssertEqual(sorted.map(\.name), ["downB", "downA", "upA"])
    }

    // K19: fromMs — 各范围的先后关系（all=0 ≤ 30d ≤ 7d ≤ today）
    func testFromMsRangeOrdering() {
        let from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let to = Date()
        let all = AlertLogModel.fromMs(range: .all, customFrom: from, customTo: to)
        let d30 = AlertLogModel.fromMs(range: .last30Days, customFrom: from, customTo: to)
        let d7 = AlertLogModel.fromMs(range: .last7Days, customFrom: from, customTo: to)
        let today = AlertLogModel.fromMs(range: .today, customFrom: from, customTo: to)

        XCTAssertEqual(all, 0, "all = unbounded")
        XCTAssertLessThanOrEqual(d30, d7)
        XCTAssertLessThanOrEqual(d7, today)
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        XCTAssertEqual(Double(today), startOfToday, accuracy: 1)
    }

    // K20: fromMs — custom 取 min(from, to) 并截断到本地零点，避免用户把日期填反
    func testFromMsCustomUsesEarlierDate() {
        let cal = Calendar.current
        let later = cal.date(byAdding: .day, value: -1, to: Date())!
        let earlier = cal.date(byAdding: .day, value: -5, to: Date())!
        let ms = AlertLogModel.fromMs(range: .custom, customFrom: later, customTo: earlier)
        // 源码对 min(from,to) 再做 startOfDay 截断
        let expected = cal.startOfDay(for: earlier).timeIntervalSince1970 * 1000
        XCTAssertEqual(Double(ms), expected, accuracy: 1)
    }
}
