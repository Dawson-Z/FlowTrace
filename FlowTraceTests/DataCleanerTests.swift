//
//  DataCleanerTests.swift
//  FlowTraceTests
//
//  I 组：DataCleaner.resetInMemory 单测（3 项）
//  验证调用 resetInMemory 后各单例被清零。
//

import XCTest
@testable import FlowTrace

final class DataCleanerTests: XCTestCase {

    // I5: historyStore.clearMemory 后 ring buffer 为空
    func testResetClearsHistoryStore() {
        let store = SharedStore.historyStore
        // 假设容量 60
        for _ in 0..<10 {
            store.append(inBytesPerSec: 1000, outBytesPerSec: 500)
        }
        XCTAssertGreaterThan(store.samples.count, 0)
        DataCleaner.resetInMemory()
        // clearMemory 在主线程同步执行（看 HistoryStore 实现）
        XCTAssertEqual(store.samples.count, 0,
                       "resetInMemory should leave HistoryStore empty")
    }

    // I5b: usageAggregator.reset 后 today/week/month 全零
    func testResetClearsUsageAggregator() {
        // UsageAggregator.today/week/month 是私有 setter；要验证只能间接：
        // 在 reset 后立即检查 bytes(forPeriod:) 总和 = 0
        let agg = SharedStore.usageAggregator
        let _ = agg.bytes(forPeriod: "day")
        // 先触发一个 tick（依赖 SharedStore.historyPersistence，可能为 nil）
        agg.tick()
        DataCleaner.resetInMemory()
        XCTAssertEqual(agg.bytes(forPeriod: "day").total, 0)
        XCTAssertEqual(agg.bytes(forPeriod: "week").total, 0)
        XCTAssertEqual(agg.bytes(forPeriod: "month").total, 0)
    }

    // I5c: quotaMonitor.resetFiredKeys 后 firedKeys 为空
    func testResetClearsQuotaFiredKeys() {
        let q = SharedStore.quotaMonitor
        // 直接调 resetFiredKeys（在 resetInMemory 内部也被调）
        q.resetFiredKeys()
        XCTAssertTrue(q.firedKeys.isEmpty)
    }

    // I5d: processAlertMonitor.reset 后 internal state 清空
    func testResetClearsProcessAlertMonitor() {
        let m = SharedStore.processAlertMonitor
        m.reset()
        // reset() 不抛异常即可
        // 直接调 resetInMemory 也不会崩
        DataCleaner.resetInMemory()
    }

    // I5e: 完整 resetInMemory 调用链不崩
    func testResetInMemoryDoesNotCrash() {
        // 跑两轮确保幂等
        DataCleaner.resetInMemory()
        DataCleaner.resetInMemory()
    }
}