//
//  SharedStoreWiringTests.swift
//  FlowTraceTests
//
//  L2-16 ~ L2-19：单例容器的装配与降级。
//
//  ⚠️ 进程级副作用：SharedStore.historyPersistence 只能 nil → 实例，无法还原
//  （docs/TESTING.md §3.3）。因此本文件的库文件不删除，且全套测试中不存在
//  「断言 historyPersistence == nil」的用例。
//

import XCTest
@testable import FlowTrace

final class SharedStoreWiringTests: XCTestCase {

    // MARK: - L2-16 / L2-17  换装后真的落库
    // 注意：这里**不**断言装配前为 nil——attach 不可逆，用例执行顺序无保证
    // （docs/TESTING.md §3.3 规则 2）。

    func testFramesAppendedAfterAttachReachDisk() {
        let p = SharedTestPersistence.attach("wiring-append")

        XCTAssertNotNil(SharedStore.historyPersistence, "attach 之后必须非 nil")
        XCTAssertEqual(SharedStore.historyStore.capacity, 60,
                       "attachHistoryPersistence 会换成一个 capacity 60 的新实例")

        for i in 0..<5 {
            SharedStore.historyStore.append(inBytesPerSec: 1000 + i, outBytesPerSec: 100)
        }

        let ok = pollUntil(timeout: 3) { p.recent(limit: 10).count == 5 }
        XCTAssertTrue(ok, "换装后的 historyStore.append 必须把帧写到该库")

        let rows = p.recent(limit: 10)
        XCTAssertEqual(rows.map(\.inBytesPerSec), [1000, 1001, 1002, 1003, 1004])
        XCTAssertTrue(SharedStore.historyStore.samples.count == 5,
                      "内存环形缓冲同时更新")
    }

    // MARK: - L2-18  resetInMemory 只清内存，不动磁盘

    func testResetInMemoryClearsMemoryButKeepsDiskRows() {
        let p = SharedTestPersistence.attach("wiring-reset")

        SharedStore.historyStore.append(inBytesPerSec: 1234, outBytesPerSec: 56)
        XCTAssertTrue(pollUntil(timeout: 3) { p.recent(limit: 10).count == 1 })

        DataCleaner.resetInMemory()

        XCTAssertEqual(SharedStore.historyStore.samples.count, 0, "内存必须立刻清空")
        XCTAssertTrue(p.recent(limit: 10).count == 1,
                      "磁盘行不得被 resetInMemory 删除——磁盘删除归 Settings 的 deleteRange")
    }

    // MARK: - L2-19  nil 持久化时消费者全部降级而不崩

    func testConsumersDegradeWhenPersistenceIsNil() {
        // 消费者层用显式 nil 构造（不改 SharedStore，避免不可逆副作用）
        let store = HistoryStore(capacity: 8, persistence: nil)
        store.append(inBytesPerSec: 100, outBytesPerSec: 10)
        store.bootstrap()
        store.clearMemory()
        XCTAssertEqual(store.samples.count, 0)
        XCTAssertEqual(store.summary, .empty)

        // 无持久化时周期总量保持 0，不崩
        let aggregator = UsageAggregator(minFetchInterval: 0)
        aggregator.tick()
        XCTAssertEqual(aggregator.bytes(forPeriod: "day").total, 0)
        aggregator.reset()

        // 分钟聚合器：persistence 为 nil 时只累积、不写盘
        let minuteAgg = InterfaceMinuteAggregator()
        var snap = InterfaceSnapshot()
        snap.bytesIn[.wifi] = 100
        let base = Date(timeIntervalSince1970: 1_788_516_000)
        minuteAgg.feed(snap, now: base, persistence: nil)
        minuteAgg.feed(snap, now: base.addingTimeInterval(60), persistence: nil)  // 触发 flush → 无 persistence，静默跳过
        minuteAgg.reset()

        // 进程用量聚合器：persistence 闭包返回 nil
        let usageAgg = ProcessUsageAggregator { nil }
        usageAgg.feed(entities: [ProcessEntity(pid: 1, name: "x",
                                               inBytesPerSec: 100, outBytesPerSec: 10)],
                      interval: 1, now: base)
        usageAgg.feed(entities: [ProcessEntity(pid: 1, name: "x",
                                               inBytesPerSec: 100, outBytesPerSec: 10)],
                      interval: 1, now: base.addingTimeInterval(60))

        // 历史窗口模型：无持久化时 reload 是 no-op
        let heatmap = HistoryHeatmapModel()
        heatmap.reload()
        XCTAssertTrue(heatmap.cells.isEmpty)
    }
}
