//
//  SearchFilterTests.swift
//  FlowTraceTests
//
//  B 组：进程搜索纯函数测试（5 项）
//  覆盖 SearchFilter.filter 的所有边界：空查询、空白、大小写、PID 数字匹配。
//

import XCTest
@testable import FlowTrace

final class SearchFilterTests: XCTestCase {

    private func entity(_ pid: Int, _ name: String) -> ProcessEntity {
        ProcessEntity(pid: pid, name: name, inBytesPerSec: 0, outBytesPerSec: 0)
    }

    // B1: 空字符串保留全部（不切数组）
    func testEmptySearchReturnsOriginal() {
        let items = [
            entity(1, "Chrome"),
            entity(2, "Safari"),
        ]
        let result = SearchFilter.filter(items: items, searchText: "")
        // 源码约定：trim 后空串直接 return items
        XCTAssertEqual(result.map(\.pid), items.map(\.pid))
        XCTAssertEqual(result.map(\.name), items.map(\.name))
        XCTAssertEqual(result.count, 2)
    }

    // B2: 空白等同于空字符串
    func testWhitespaceOnlyReturnsOriginal() {
        let items = [
            entity(1, "Chrome"),
            entity(2, "Safari"),
        ]
        let result = SearchFilter.filter(items: items, searchText: "   ")
        XCTAssertEqual(result.count, 2)
    }

    // B3: 大小写不敏感
    func testCaseInsensitiveNameMatch() {
        let items = [
            entity(1, "Google Chrome"),
            entity(2, "CHROME"),
            entity(3, "chrome"),
            entity(4, "Safari"),
        ]
        let result = SearchFilter.filter(items: items, searchText: "chrome")
        let pids = Set(result.map(\.pid))
        XCTAssertEqual(pids, [1, 2, 3])
        XCTAssertFalse(pids.contains(4))
    }

    // B4: PID 精确匹配（needle 可解析为 Int 且相等）
    func testPIDExactMatch() {
        let items = [
            entity(1234, "Chrome"),
            entity(12, "Random"),     // name 含 "12"，但 PID 12
            entity(12345, "Safari"),
        ]
        // 搜 "1234" 应该只命中 PID=1234
        let result = SearchFilter.filter(items: items, searchText: "1234")
        XCTAssertEqual(result.map(\.pid), [1234])
    }

    // B5: 同时支持名称 / PID
    func testNameAndPIDBothWork() {
        let items = [
            entity(1, "ssh"),
            entity(123, "Random"),     // PID 包含 "123"
            entity(2, "Bob's iPhone"),
        ]
        // 搜 "ssh" 应该命中 PID=1（name）
        let byName = SearchFilter.filter(items: items, searchText: "ssh")
        XCTAssertEqual(byName.map(\.pid), [1])

        // 搜 "123" 应该同时命中 name 含 123 的不存在项 + PID=123 的项
        // 源码逻辑：先 name predicate（contains），再 PID 数字等值
        // 这里仅 PID=123 命中（name 都不含 "123"）
        let byPid = SearchFilter.filter(items: items, searchText: "123")
        XCTAssertEqual(byPid.map(\.pid), [123])
    }

    // B6/B7 见 ListViewModelSortTests.testIdempotent 与 ListViewModelMergeTests 已覆盖
}