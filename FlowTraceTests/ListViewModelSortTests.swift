//
//  ListViewModelSortTests.swift
//  FlowTraceTests
//
//  Unit tests for ListViewModel.sort(items:mode:).
//
//  These tests cover the comparator only. They do *not* cover:
//    - Picker binding (SwiftUI, not our code)
//    - searchText filtering (covered by SearchFilter's own semantics)
//    - updateData's PID-merge logic (covered in ListViewModelMergeTests)
//
//  The comparator is value-in / value-out, so the test does not need
//  SharedStore, network, or any GUI setup. A fresh ListViewModel with
//  default sortMode is enough; we mutate sortMode to drive each case.
//
//  Note on the cumulative modes: `.todayDownload` / `.todayUpload` /
//  `.todayTotal` sort on `todayUsage`, which is a plain dictionary keyed by
//  the lowercased display name — so a test seeds it directly instead of
//  running the frame pipeline.
//

import XCTest
@testable import FlowTrace

final class ListViewModelSortTests: XCTestCase {

    // MARK: - Fixtures
    // Names chosen so the secondary `name` tie-breaker is deterministic
    // and never accidentally happens to coincide with rate order.
    private func fixture() -> [ProcessEntity] {
        return [
            ProcessEntity(pid: 1, name: "alpha",   inBytesPerSec: 100, outBytesPerSec:  10),
            ProcessEntity(pid: 2, name: "BRAVO",   inBytesPerSec: 200, outBytesPerSec:  50),
            ProcessEntity(pid: 3, name: "Charlie", inBytesPerSec:   0, outBytesPerSec: 500),
            ProcessEntity(pid: 4, name: "delta",   inBytesPerSec: 150, outBytesPerSec: 150),
        ]
    }

    private func makeVM() -> ListViewModel {
        // The default sortMode is seeded from SettingsStore.defaultSortModeRaw
        // (`.downloadRate` on a fresh install); every test sets its own.
        return ListViewModel()
    }

    // MARK: - Live rates

    func testDownloadRateSort() {
        let vm = makeVM()
        vm.sortMode = .downloadRate
        let sorted = vm.sort(items: fixture())
        // In: 200, 150, 100, 0
        XCTAssertEqual(sorted.map(\.pid), [2, 4, 1, 3])
    }

    func testUploadRateSort() {
        let vm = makeVM()
        vm.sortMode = .uploadRate
        let sorted = vm.sort(items: fixture())
        // Out: 500, 150, 50, 10
        XCTAssertEqual(sorted.map(\.pid), [3, 4, 2, 1])
    }

    // MARK: - Cumulative (today)

    func testTodayTotalSort() {
        let vm = makeVM()
        vm.sortMode = .todayTotal
        vm.todayUsage = [
            "alpha":   (inBytes: 100, outBytes:  10),   // 110
            "bravo":   (inBytes: 200, outBytes:  50),   // 250
            "charlie": (inBytes:   0, outBytes: 500),   // 500
            "delta":   (inBytes: 150, outBytes: 150),   // 300
        ]
        let sorted = vm.sort(items: fixture())
        // Totals: 500, 300, 250, 110
        XCTAssertEqual(sorted.map(\.pid), [3, 4, 2, 1])
    }

    func testTodayDownloadSort() {
        let vm = makeVM()
        vm.sortMode = .todayDownload
        vm.todayUsage = [
            "alpha":   (inBytes:  10, outBytes: 0),
            "bravo":   (inBytes: 200, outBytes: 0),
            "charlie": (inBytes:   0, outBytes: 0),
            "delta":   (inBytes: 150, outBytes: 0),
        ]
        XCTAssertEqual(vm.sort(items: fixture()).map(\.pid), [2, 4, 1, 3])
    }

    func testTodayUploadSort() {
        let vm = makeVM()
        vm.sortMode = .todayUpload
        vm.todayUsage = [
            "alpha":   (inBytes: 0, outBytes:  10),
            "bravo":   (inBytes: 0, outBytes:  50),
            "charlie": (inBytes: 0, outBytes: 500),
            "delta":   (inBytes: 0, outBytes: 150),
        ]
        XCTAssertEqual(vm.sort(items: fixture()).map(\.pid), [3, 4, 2, 1])
    }

    // MARK: - Name

    func testNameSort() {
        let vm = makeVM()
        vm.sortMode = .name
        let names = vm.sort(items: fixture()).map { $0.name.lowercased() }
        // Case-insensitive: alpha, BRAVO, Charlie, delta. Compared
        // lowercased so the assertion does not depend on the machine's
        // locale collation.
        XCTAssertEqual(names, ["alpha", "bravo", "charlie", "delta"])
    }

    // MARK: - Tie-breaker
    // Two processes with identical sort keys must end up in name order.
    func testTieBreakerOnEqualRates() {
        let vm = makeVM()
        vm.sortMode = .downloadRate
        let items = [
            ProcessEntity(pid: 10, name: "zulu",  inBytesPerSec: 100, outBytesPerSec: 100),
            ProcessEntity(pid: 11, name: "ALPHA", inBytesPerSec: 100, outBytesPerSec: 100),
        ]
        XCTAssertEqual(vm.sort(items: items).map(\.name), ["ALPHA", "zulu"])
    }

    // MARK: - Empty / single
    func testEmpty() {
        let vm = makeVM()
        for mode in ListSortMode.allCases {
            vm.sortMode = mode
            XCTAssertTrue(vm.sort(items: []).isEmpty, "mode=\(mode)")
        }
    }

    func testSingle() {
        let vm = makeVM()
        for mode in ListSortMode.allCases {
            vm.sortMode = mode
            let only = [ProcessEntity(pid: 1, name: "lonely", inBytesPerSec: 0, outBytesPerSec: 0)]
            XCTAssertEqual(vm.sort(items: only).map(\.pid), [1], "mode=\(mode)")
        }
    }

    // MARK: - Stability under repeated sort
    // The function must be referentially transparent: sorting an already
    // sorted list with the same mode is a no-op.
    func testIdempotent() {
        let vm = makeVM()
        for mode in ListSortMode.allCases {
            vm.sortMode = mode
            let once = vm.sort(items: fixture())
            let twice = vm.sort(items: once)
            XCTAssertEqual(once.map(\.pid), twice.map(\.pid), "mode=\(mode)")
        }
    }
}
