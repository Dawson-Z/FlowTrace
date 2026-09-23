//
//  CSVExporterTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：CSVExporter 三种 CSV 形状 + 转义（4 项）
//

import XCTest
@testable import FlowTrace

final class CSVExporterTests: XCTestCase {

    private let t = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12, minute: 30))!

    // K13: processCSV 形状与行内容
    func testProcessCSVShape() {
        let csv = CSVExporter.processCSV([
            (time: t, name: "Chrome", inBytes: 100, outBytes: 20),
        ])
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Time,Process,Download (bytes),Upload (bytes)")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix(",Chrome,100,20"))
    }

    // K14: 含逗号 / 引号的名称被转义
    func testEscaping() {
        let csv = CSVExporter.processCSV([
            (time: t, name: "App, \"quoted\"", inBytes: 1, outBytes: 2),
        ])
        let dataLine = csv.split(separator: "\n")[1]
        // "App, ""quoted""" — 引号翻倍、整体加引号
        XCTAssertTrue(dataLine.contains("\"App, \"\"quoted\"\"\""),
                      "comma and quotes must be escaped, got: \(dataLine)")
    }

    // K15: alertCSV — baseline=0 时 Factor 列为空
    func testAlertCSVFactorEmptyWhenBaselineZero() {
        let record = AlertRecord(date: t, name: "x", isIn: true,
                                 todayBytes: 500, baselineBytes: 0, multiplier: 0)
        let csv = CSVExporter.alertCSV([record])
        let line = csv.split(separator: "\n")[1]
        XCTAssertTrue(line.hasSuffix(",500,0,"),
                      "zero baseline leaves Factor empty (undefined ratio), got: \(line)")
    }

    // K16: alertCSV — 方向词与 factor 值
    func testAlertCSVDirectionAndFactor() {
        let rec = AlertRecord(date: t, name: "y", isIn: false,
                              todayBytes: 1000, baselineBytes: 100, multiplier: 10)
        let csv = CSVExporter.alertCSV([rec])
        let line = csv.split(separator: "\n")[1]
        XCTAssertTrue(line.contains(",out,"), "upload direction is stored as 'out'")
        XCTAssertTrue(line.hasSuffix(",1000,100,10.00"))
    }
}
