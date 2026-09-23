//
//  TestSupport.swift
//  FlowTraceTests
//
//  L2 各测试文件共用的帮手。
//

import XCTest
import Foundation
@testable import FlowTrace

// MARK: - 异步读等待

/// 等待一次异步回调并取回其值。超时即 XCTFail 并返回 nil（调用方解包）。
func awaitValue<T>(_ timeout: TimeInterval = 3.0,
                   file: StaticString = #filePath, line: UInt = #line,
                   _ start: (@escaping (T) -> Void) -> Void) -> T? {
    let exp = XCTestExpectation(description: "awaitValue")
    var result: T?
    start { value in
        result = value
        exp.fulfill()
    }
    let outcome = XCTWaiter().wait(for: [exp], timeout: timeout)
    if outcome != .completed {
        XCTFail("awaitValue 超时（\(timeout)s）", file: file, line: line)
    }
    return result
}

/// 轮询直到条件成立。会泵主 runloop，因此 Combine 的 `receive(on: .main)`
/// 与 `DispatchQueue.main.async` 都能推进。
@discardableResult
func pollUntil(timeout: TimeInterval = 3.0,
               interval: TimeInterval = 0.02,
               _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    }
    return condition()
}

// MARK: - SharedStore 换装专用临时库

/// `SharedStore.historyPersistence` 是 `static private(set) var`，唯一写入口是
/// `attachHistoryPersistence(_:)`——**只能 nil → 实例，无法还原**（见 docs/TESTING.md §3.3）。
/// 因此这里分配的库文件**不删除**：后续任何仍持有该引用的消费者（如
/// `DataCleaner.resetInMemory` 触发的读）不会写到一个已消失的路径上。
/// 目录位于 `NSTemporaryDirectory()` 下，由系统定期清理。
enum SharedTestPersistence {

    static let directory: URL = {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-shared-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 新建一个库并挂到 `SharedStore`。
    @discardableResult
    static func attach(_ name: String) -> HistoryPersistence {
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite3")
        let p = HistoryPersistence(dbURL: url, retentionSeconds: 3600)!
        SharedStore.attachHistoryPersistence(p)
        return p
    }
}

// MARK: - 独立临时库（不挂 SharedStore）

/// 每个用例一个新库，`tearDown` 里删除（含 WAL/SHM 边车）。
class TempDatabaseTestCase: XCTestCase {

    private var urls: [URL] = []

    func makePersistence(retentionSeconds: TimeInterval = 3600) -> HistoryPersistence {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FlowTraceTests-db-\(UUID().uuidString).sqlite3")
        urls.append(url)
        return HistoryPersistence(dbURL: url, retentionSeconds: retentionSeconds)!
    }

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        urls = []
        super.tearDown()
    }
}

// MARK: - 独立 UserDefaults suite
class TempDefaultsTestCase: XCTestCase {

    private var suiteNames: [String] = []

    func makeDefaults() -> UserDefaults {
        let name = "FlowTraceTests.suite.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }
}
