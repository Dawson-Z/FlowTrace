//
//  UtilsFormatBytesTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：formatBytes / formatBytesCompact（6 项）
//  formatBytes 是菜单栏速率显示（0.3.0 milestone 2 加了 GB 档）；
//  formatBytesCompact 是列表行内紧凑格式。
//

import XCTest
@testable import FlowTrace

final class UtilsFormatBytesTests: XCTestCase {

    // K7: formatBytes 阶梯
    func testFormatBytesTiers() {
        XCTAssertEqual(formatBytes(bytes: 0), "0 KB/s")
        XCTAssertEqual(formatBytes(bytes: -5), "0 KB/s")
        XCTAssertEqual(formatBytes(bytes: 512), "0.5 KB/s")
        XCTAssertEqual(formatBytes(bytes: 1024), "1.0 KB/s")
        XCTAssertEqual(formatBytes(bytes: 1024 * 1024), "1.0 MB/s")
        XCTAssertEqual(formatBytes(bytes: 1024 * 1024 * 1024), "1.0 GB/s")
        // GB 档回归（milestone 2 之前菜单栏会显示 "1024.0 MB/s"）
        XCTAssertFalse(formatBytes(bytes: 1024 * 1024 * 1024).contains("MB"))
    }

    // K8: formatBytesCompact 阶梯
    func testFormatBytesCompactTiers() {
        XCTAssertEqual(formatBytesCompact(bytes: 0), "—")
        XCTAssertEqual(formatBytesCompact(bytes: -1), "—")
        // 低于 0.05K (51.2 B) 显示 —
        XCTAssertEqual(formatBytesCompact(bytes: 10), "—")
        // K 档
        XCTAssertEqual(formatBytesCompact(bytes: 1024), "1.0K")
        XCTAssertEqual(formatBytesCompact(bytes: 55 * 1024), "55K")
        // M 档
        XCTAssertEqual(formatBytesCompact(bytes: 1024 * 1024), "1.0M")
        XCTAssertEqual(formatBytesCompact(bytes: 9 * 1024 * 1024), "9.0M")
        XCTAssertEqual(formatBytesCompact(bytes: 100 * 1024 * 1024), "100M")
        // G 档
        XCTAssertEqual(formatBytesCompact(bytes: 1024 * 1024 * 1024), "1.0G")
        XCTAssertEqual(formatBytesCompact(bytes: 5 * 1024 * 1024 * 1024), "5.0G")
        XCTAssertEqual(formatBytesCompact(bytes: 50 * 1024 * 1024 * 1024), "50G")
    }

    // K9: ByteFormatter（配额通知用）
    func testByteFormatter() {
        XCTAssertEqual(ByteFormatter.string(bytes: 512), "0 KB")     // <1000 KB
        XCTAssertEqual(ByteFormatter.string(bytes: 500 * 1024), "500 KB")
        XCTAssertEqual(ByteFormatter.string(bytes: 1024 * 1024), "1.0 MB")
        XCTAssertEqual(ByteFormatter.string(bytes: 2 * 1024 * 1024 * 1024), "2.00 GB")
    }

    // K10: compact 阈值 0.05K 边界
    func testCompactJustBelowAndAboveThreshold() {
        // 51 bytes = 0.0498K < 0.05 → —
        XCTAssertEqual(formatBytesCompact(bytes: 51), "—")
        // 60 bytes = 0.0586K ≥ 0.05 → "0.1K"
        XCTAssertEqual(formatBytesCompact(bytes: 60), "0.1K")
    }

    // K11: formatBytes 大数值
    func testFormatBytesLargeValues() {
        // 1.5 GB/s
        let v = formatBytes(bytes: Int(1.5 * 1024 * 1024 * 1024))
        XCTAssertEqual(v, "1.5 GB/s")
    }

    // K12: compact 不带 /s 后缀（列宽约定）
    func testCompactHasNoPerSecondSuffix() {
        XCTAssertFalse(formatBytesCompact(bytes: 2048).contains("/s"))
    }
}
