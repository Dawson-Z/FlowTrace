//
//  ProcessAlertMonitorTests.swift
//  FlowTraceTests
//
//  E 组：ProcessAlertMonitor 单测（8 项）
//  重点：decide() 纯函数边界、median 边界；持久化调用回放走 SharedStore.historyPersistence，
//  此处注入替身太重，因此只覆盖静态/纯函数路径。
//

import XCTest
@testable import FlowTrace

final class ProcessAlertMonitorTests: XCTestCase {

    // E1: 双条件同时满足
    func testDecideBothConditionsMet() {
        let d = ProcessAlertMonitor.decide(
            todayBytes: 500 * 1024 * 1024,
            baselineBytes: 50 * 1024 * 1024,
            floorBytes: 500 * 1024 * 1024,
            multiplier: 10
        )
        XCTAssertTrue(d.shouldAlert)
        // 因子 = today / baseline = 10
        XCTAssertEqual(d.multiplier, 10, accuracy: 0.01)
    }

    // E2: floor 满足但因子不满足
    func testDecideFloorMetButFactorNot() {
        let d = ProcessAlertMonitor.decide(
            todayBytes: 600 * 1024 * 1024,
            baselineBytes: 100 * 1024 * 1024,    // 因子 = 6 < 10
            floorBytes: 500 * 1024 * 1024,
            multiplier: 10
        )
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.multiplier, 6, accuracy: 0.01)
    }

    // E3: 零基线 + 流量超 floor → alert
    // 注意：源码规则 floorOk = today >= floor，无 zero-baseline 例外。
    // 此处测试 baseline=0 且 today 超 floor 的"零基线异常"路径。
    func testDecideZeroBaselineTrafficAboveFloor() {
        let d = ProcessAlertMonitor.decide(
            todayBytes: 600 * 1024 * 1024,  // 超 500MB floor
            baselineBytes: 0,
            floorBytes: 500 * 1024 * 1024,
            multiplier: 10
        )
        XCTAssertTrue(d.shouldAlert)
        XCTAssertEqual(d.multiplier, 0, "baseline=0 → multiplier encoded as 0 (∞)")
    }

    // E3b: 零基线但流量低于 floor → 不 alert（双条件中 floor 没满足）
    func testDecideZeroBaselineTrafficBelowFloor() {
        let d = ProcessAlertMonitor.decide(
            todayBytes: 100 * 1024 * 1024,
            baselineBytes: 0,
            floorBytes: 500 * 1024 * 1024,
            multiplier: 10
        )
        XCTAssertFalse(d.shouldAlert, "below floor + zero baseline must NOT alert (both conditions must hold)")
    }

    // E4: 零基线且零流量
    func testDecideZeroBaselineZeroTraffic() {
        let d = ProcessAlertMonitor.decide(
            todayBytes: 0,
            baselineBytes: 0,
            floorBytes: 500 * 1024 * 1024,
            multiplier: 10
        )
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.multiplier, 0)
    }

    // E5: 方向独立（直接验证 decide 是单方向函数，无耦合）
    func testDecideIndependentPerDirection() {
        // 上传、下载各算一遍，互不影响
        let d = ProcessAlertMonitor.decide(todayBytes: 500 * 1024 * 1024,
                                            baselineBytes: 50 * 1024 * 1024,
                                            floorBytes: 500 * 1024 * 1024,
                                            multiplier: 10)
        let u = ProcessAlertMonitor.decide(todayBytes: 0,
                                            baselineBytes: 0,
                                            floorBytes: 500 * 1024 * 1024,
                                            multiplier: 10)
        XCTAssertTrue(d.shouldAlert)
        XCTAssertFalse(u.shouldAlert)
    }

    // E8: median 奇偶
    func testMedianOdd() {
        XCTAssertEqual(ProcessAlertMonitor.median([1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(ProcessAlertMonitor.median([5, 1, 3]), 3)
        XCTAssertEqual(ProcessAlertMonitor.median([9]), 9)
    }

    func testMedianEven() {
        XCTAssertEqual(ProcessAlertMonitor.median([1, 2, 3, 4]), 2)
        // 整数除法取整：(2+3)/2 = 2 (当 [4,3] 排序后 mid-1=1, mid=3)
        XCTAssertEqual(ProcessAlertMonitor.median([1, 2, 3, 4, 5, 6]), 3)
        XCTAssertEqual(ProcessAlertMonitor.median([]), 0)
    }

    // E6/E7：依赖持久化层；持久化测试在 G 组用临时 DB 验证 UNIQUE 索引。
    // 这里只验证 dayOrdinal 是 Int 且与 Date.now 一一对应。
    func testDayOrdinalIsInteger() {
        let now = Date()
        let ord = ProcessAlertMonitor.dayOrdinal(now)
        XCTAssertGreaterThan(ord, 19000)  // 2022+ 的天数序数
        let ord2 = ProcessAlertMonitor.dayOrdinal(now.addingTimeInterval(86400))
        XCTAssertEqual(ord2, ord + 1)
    }
}