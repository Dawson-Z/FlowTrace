//
//  InterfaceModelTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：InterfaceModel 快照发布 / 今日累计 / reset（4 项）
//

import XCTest
@testable import FlowTrace

final class InterfaceModelTests: XCTestCase {

    private func snap(_ wifiIn: Int, _ wifiOut: Int) -> InterfaceSnapshot {
        var s = InterfaceSnapshot()
        s.bytesIn[.wifi] = wifiIn
        s.bytesOut[.wifi] = wifiOut
        return s
    }

    // K32: update — 相同快照不重复发布，不同才发布
    func testUpdateOnlyPublishesOnChange() {
        let m = InterfaceModel()
        var published = 0
        let obs = m.$snapshot.dropFirst().sink { _ in published += 1 }

        m.update(snap(100, 50))
        m.update(snap(100, 50))   // 相同 → 不发布
        m.update(snap(200, 50))
        XCTAssertEqual(published, 2, "identical snapshots must not republish")
        obs.cancel()
    }

    // K33: trackTodayFrame 累计会话增量
    func testTrackTodayFrameAccumulates() {
        let m = InterfaceModel()
        m.trackTodayFrame(snap(100, 50))
        m.trackTodayFrame(snap(100, 50))
        let row = m.todayUsage["Wi-Fi"]
        XCTAssertEqual(row?.in, 200, "two frames of 100 in = 200")
        XCTAssertEqual(row?.out, 100)
    }

    // K34: trackTodayFrame 对未出现类别不造零行
    func testTrackTodayFrameSkipsAbsentCategories() {
        let m = InterfaceModel()
        var s = InterfaceSnapshot()
        s.bytesIn[.wifi] = 10
        m.trackTodayFrame(s)
        XCTAssertNil(m.todayUsage["Wired"], "absent category must not appear")
        XCTAssertNil(m.todayUsage["Other"])
    }

    // K35: reset 清空快照与今日累计
    func testReset() {
        let m = InterfaceModel()
        m.trackTodayFrame(snap(100, 50))
        m.update(snap(100, 50))
        m.reset()
        XCTAssertEqual(m.snapshot, .empty)
        XCTAssertTrue(m.todayUsage.isEmpty)
    }
}
