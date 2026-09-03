//
//  ListViewModelSortTests.swift
//  iTrafficPlusTests
//
//  Unit tests for ListViewModel.sort(items:).
//
//  These tests cover the comparator only. They do *not* cover:
//    - Picker binding (SwiftUI, not our code)
//    - searchText filtering (covered in ProcessSearchBarTests / ContentView)
//    - updateData's PID-merge logic (covered in updateDataTests, if added)
//
//  The sort function is value-in / value-out, so the test does not need
//  SharedStore, network, or any GUI setup. A fresh ListViewModel with
//  default sortMode is enough; we mutate sortMode to drive each case.
//

import XCTest
@testable import iTrafficPlus

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
        // Default sortMode is .total; each test sets what it needs.
        return ListViewModel()
    }

    // MARK: - .total (default)
    func testTotalSort() {
        let vm = makeVM()
        vm.sortMode = .total
        let sorted = vm.sort(items: fixture())
        // Expected order:
        //   pid 2 BRAVO   (250)
        //   pid 4 delta   (300)
        //   pid 1 alpha   (110)
        //   pid 3 Charlie (500)
        // By totals: 500, 300, 250, 110
        XCTAssertEqual(sorted.map(\.pid), [3, 4, 2, 1])
    }

    // MARK: - .download
    func testDownloadSort() {
        let vm = makeVM()
        vm.sortMode = .download
        let sorted = vm.sort(items: fixture())
        // In: 200, 150, 100, 0
        XCTAssertEqual(sorted.map(\.pid), [2, 4, 1, 3])
    }

    // MARK: - .upload
    func testUploadSort() {
        let vm = makeVM()
        vm.sortMode = .upload
        let sorted = vm.sort(items: fixture())
        // Out: 500, 150, 50, 10
        XCTAssertEqual(sorted.map(\.pid), [3, 4, 2, 1])
    }

    // MARK: - .name
    func testNameSort() {
        let vm = makeVM()
        vm.sortMode = .name
        let sorted = vm.sort(items: fixture())
        // Case-insensitive: alpha, BRAVO, Charlie, delta
        // But localizedCaseInsensitiveCompare uses the current locale.
        // Pin to ASCII-ascending explicitly to make the test stable.
        let names = sorted.map(\.name).map { $0.lowercased() }
        XCTAssertEqual(names, ["alpha", "bravo", "charlie", "delta"])
    }

    // MARK: - Tie-breaker
    // Two processes with identical total rates must end up in name order.
    func testTieBreakerOnTotal() {
        let vm = makeVM()
        vm.sortMode = .total
        let items = [
            ProcessEntity(pid: 10, name: "zulu",  inBytesPerSec: 100, outBytesPerSec: 100),
            ProcessEntity(pid: 11, name: "ALPHA", inBytesPerSec: 100, outBytesPerSec: 100),
        ]
        let sorted = vm.sort(items: items)
        XCTAssertEqual(sorted.map(\.name), ["ALPHA", "zulu"])
    }

    // MARK: - Empty / single
    func testEmpty() {
        let vm = makeVM()
        for mode in ListSortMode.allCases {
            vm.sortMode = mode
            XCTAssertEqual(vm.sort(items: []), [])
        }
    }

    func testSingle() {
        let vm = makeVM()
        for mode in ListSortMode.allCases {
            vm.sortMode = mode
            let only = [ProcessEntity(pid: 1, name: "lonely", inBytesPerSec: 0, outBytesPerSec: 0)]
            XCTAssertEqual(vm.sort(items: only).map(\.pid), [1])
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
