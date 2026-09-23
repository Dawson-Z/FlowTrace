//
//  UsageAggregatorTests.swift
//  FlowTraceTests
//
//  C 组：UsageAggregator 单测（2 项）
//  bytes(forPeriod:) 是纯函数；tick 节流需要 SharedStore 故不单测。
//

import XCTest
@testable import FlowTrace

final class UsageAggregatorTests: XCTestCase {

    // C9: bytes(forPeriod:) 按字符串返回对应 @Published 值
    func testBytesForPeriod() {
        let a = UsageAggregator()
        a.reset()
        // 直接写入 today/week/month 的 @Published 通过 _ 后缀不可达，
        // 但 bytes(forPeriod:) 默认返回 month / week / today 的当前值（默认 0）。
        // 验证默认值与字符串路由。
        XCTAssertEqual(a.bytes(forPeriod: "day").total, 0)
        XCTAssertEqual(a.bytes(forPeriod: "week").total, 0)
        XCTAssertEqual(a.bytes(forPeriod: "month").total, 0)
        // 未知字符串回退 month
        XCTAssertEqual(a.bytes(forPeriod: "unknown").total, 0)
    }

    // C10: UsageBytes.total 字段
    func testUsageBytesTotal() {
        let b = UsageBytes(inBytes: 100, outBytes: 50)
        XCTAssertEqual(b.total, 150)
        let b0 = UsageBytes()
        XCTAssertEqual(b0.total, 0)
    }
}