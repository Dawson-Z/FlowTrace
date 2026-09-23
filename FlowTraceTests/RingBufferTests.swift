//
//  RingBufferTests.swift
//  FlowTraceTests
//
//  补充轮 K 组：RingBuffer 纯数据结构（6 项）
//

import XCTest
@testable import FlowTrace

final class RingBufferTests: XCTestCase {

    // K1: FIFO 顺序（未满时）
    func testFIFOOrderWhenNotFull() {
        var b = RingBuffer<Int>(capacity: 5)
        b.append(1); b.append(2); b.append(3)
        XCTAssertEqual(b.snapshot(), [1, 2, 3])
        XCTAssertEqual(b.count, 3)
    }

    // K2: 环形回绕：超出容量后丢弃最旧
    func testWrapsAroundAndDropsOldest() {
        var b = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { b.append(i) }
        XCTAssertEqual(b.snapshot(), [3, 4, 5], "oldest (1,2) must be evicted")
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.capacity, 3)
    }

    // K3: snapshot 的最新元素在末尾（sparkline 左旧右新约定）
    func testNewestElementIsLast() {
        var b = RingBuffer<Int>(capacity: 4)
        b.append(10)
        b.append(20)
        XCTAssertEqual(b.snapshot().last, 20)
        b.append(30)
        XCTAssertEqual(b.snapshot().last, 30)
    }

    // K4: removeAll 清空且可继续写入
    func testRemoveAll() {
        var b = RingBuffer<Int>(capacity: 3)
        b.append(1); b.append(2)
        b.removeAll()
        XCTAssertEqual(b.snapshot(), [])
        XCTAssertEqual(b.count, 0)
        b.append(9)
        XCTAssertEqual(b.snapshot(), [9], "buffer must be usable after removeAll")
    }

    // K5: 容量 1 的边界
    func testCapacityOne() {
        var b = RingBuffer<String>(capacity: 1)
        b.append("a")
        XCTAssertEqual(b.snapshot(), ["a"])
        b.append("b")
        XCTAssertEqual(b.snapshot(), ["b"])
    }

    // K6: 空缓冲 snapshot 为空
    func testEmptySnapshot() {
        let b = RingBuffer<Int>(capacity: 10)
        XCTAssertTrue(b.snapshot().isEmpty)
        XCTAssertEqual(b.count, 0)
    }
}
