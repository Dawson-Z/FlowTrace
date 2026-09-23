//
//  HistoryStoreTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：HistoryStore 内存环形缓冲 + bootstrap 回填（4 项）
//

import XCTest
@testable import FlowTrace

final class HistoryStoreTests: XCTestCase {

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
            .appendingPathComponent("FlowTraceTests-hstore-\(UUID().uuidString).sqlite3")
        tempURLs.append(url)
        return try XCTUnwrap(HistoryPersistence(dbURL: url, retentionSeconds: 3600))
    }

    // K28: append 发布 snapshot、容量封顶
    func testAppendPublishesAndCaps() {
        let store = HistoryStore(capacity: 5)
        for i in 0..<8 {
            store.append(inBytesPerSec: i * 100, outBytesPerSec: 0)
        }
        XCTAssertEqual(store.samples.count, 5)
        XCTAssertEqual(store.samples.map(\.inBytesPerSec), [300, 400, 500, 600, 700],
                       "oldest frames evicted, insertion order kept")
    }

    // K29: clearMemory 清空内存（不动磁盘）
    func testClearMemory() throws {
        let p = try makePersistence()
        let store = HistoryStore(capacity: 5, persistence: p)
        store.append(inBytesPerSec: 100, outBytesPerSec: 50)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(store.samples.count, 1)

        store.clearMemory()
        XCTAssertEqual(store.samples.count, 0)
        XCTAssertEqual(store.summary, .empty)
        // 磁盘行仍在
        XCTAssertEqual(p.recent(limit: 10).count, 1, "clearMemory must not touch disk")
    }

    // K30: bootstrap 从磁盘回填最近 N 帧（重启曲线不空）
    func testBootstrapSeedsFromDisk() throws {
        let p = try makePersistence()
        let store1 = HistoryStore(capacity: 4, persistence: p)
        for i in 0..<6 {
            store1.append(inBytesPerSec: i * 10, outBytesPerSec: 0)
        }
        Thread.sleep(forTimeInterval: 0.4)

        // 模拟重启：新 store 引同一个库
        let store2 = HistoryStore(capacity: 4, persistence: p)
        store2.bootstrap()
        XCTAssertEqual(store2.samples.count, 4)
        XCTAssertEqual(store2.samples.map(\.inBytesPerSec), [20, 30, 40, 50],
                       "most recent 4 rows in chronological order")
    }

    // K31: 无持久化时 bootstrap 是 no-op
    func testBootstrapWithoutPersistenceIsNoop() {
        let store = HistoryStore(capacity: 10)
        store.bootstrap()
        XCTAssertTrue(store.samples.isEmpty)
    }
}
