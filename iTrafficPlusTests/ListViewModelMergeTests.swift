//
//  ListViewModelMergeTests.swift
//  iTrafficPlusTests
//
//  Unit tests for ListViewModel.mergeSameNameProcesses(_:).
//
//  The merge is a pure value-in / value-out function over [ProcessEntity],
//  so the test needs no SharedStore, network, or GUI. It covers:
//    - collapsing rows that share a case-insensitive name
//    - summing in/out rates across the collapsed rows
//    - keeping the smallest pid (stable row identity frame-to-frame)
//    - keeping the first-seen name spelling
//    - not collapsing distinct process names
//    - idempotence (merging an already-merged list is a no-op)
//

import XCTest
@testable import iTrafficPlus

final class ListViewModelMergeTests: XCTestCase {

    private func entity(_ pid: Int, _ name: String, _ inB: Int, _ outB: Int) -> ProcessEntity {
        ProcessEntity(pid: pid, name: name, inBytesPerSec: inB, outBytesPerSec: outB)
    }

    /// Same app appearing as several PIDs collapses into one row (e.g.
    /// Electron helpers, "Trae CN Helper.86108/.86111/.86112").
    func testSameNameCollapses() {
        let input = [
            entity(86108, "Trae CN Helper", 1_000_000, 200_000),
            entity(86111, "Trae CN Helper", 100_000,  50_000),
            entity(86112, "Trae CN Helper", 100_000,  50_000),
        ]
        let merged = ListViewModel.mergeSameNameProcesses(input)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].inBytesPerSec, 1_200_000)
        XCTAssertEqual(merged[0].outBytesPerSec, 300_000)
        // pid keeps the smallest so the row identity is stable.
        XCTAssertEqual(merged[0].pid, 86108)
        XCTAssertEqual(merged[0].name, "Trae CN Helper")
    }

    /// Merge is case-insensitive: "node" and "Node" are one row.
    func testCaseInsensitiveMerge() {
        let input = [
            entity(1, "node", 100, 10),
            entity(2, "Node", 200, 20),
        ]
        let merged = ListViewModel.mergeSameNameProcesses(input)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].inBytesPerSec, 300)
        XCTAssertEqual(merged[0].outBytesPerSec, 30)
        // First-seen spelling is kept.
        XCTAssertEqual(merged[0].name, "node")
    }

    /// Distinct process names are not merged.
    func testDistinctNamesNotMerged() {
        let input = [
            entity(1, "Safari", 100, 10),
            entity(2, "Chrome", 200, 20),
        ]
        let merged = ListViewModel.mergeSameNameProcesses(input)
        XCTAssertEqual(merged.count, 2)
    }

    /// The function preserves insertion order of the first-seen names.
    func testPreservesFirstSeenOrder() {
        let input = [
            entity(3, "Delta", 30, 3),
            entity(1, "Alpha", 10, 1),
            entity(2, "Bravo", 20, 2),
        ]
        let merged = ListViewModel.mergeSameNameProcesses(input)
        XCTAssertEqual(merged.map(\.name), ["Delta", "Alpha", "Bravo"])
    }

    /// Merging an already-merged list is a no-op (referential transparency).
    func testIdempotent() {
        let input = [
            entity(86108, "Trae CN Helper", 1_000_000, 200_000),
            entity(86109, "Trae CN Helper", 100_000,  50_000),
            entity(1, "Safari", 100, 10),
        ]
        let once = ListViewModel.mergeSameNameProcesses(input)
        let twice = ListViewModel.mergeSameNameProcesses(once)
        XCTAssertEqual(once.map(\.pid), twice.map(\.pid))
        XCTAssertEqual(once.map(\.name), twice.map(\.name))
    }

    /// Empty input yields empty output.
    func testEmpty() {
        let merged = ListViewModel.mergeSameNameProcesses([])
        XCTAssertTrue(merged.isEmpty)
    }
}
