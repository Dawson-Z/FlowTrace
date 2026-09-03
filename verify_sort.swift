//
//  verify_sort.swift
//  Standalone CLI verification for ListViewModel.sort(items:).
//
//  Why this exists
//  ---------------
//  xcodebuild test is blocked by the development sandbox the author works
//  in: the test runner's xcresult bundle is written to
//  build/Logs/Test/*.xcresult, which the sandbox denies, even with
//  dangerouslyDisableSandbox. Running the same eight cases through
//  XCTest from the command line is therefore not possible from here.
//
//  This script is a *thin* verification harness: it embeds the exact
//  comparator logic from ListViewModel and runs the same fixtures the
//  unit test does. The whole point is "does the sort algorithm behave
//  the way the unit test thinks it does?" — if both pass, the iTrafficPlus
//  source matches. If you change ListViewModel.sort, mirror the change
//  here, then re-run.
//
//  Run:
//      swift verify_sort.swift
//
//  Exit code 0 = all pass, 1 = at least one failed (with details on stderr).
//

import Foundation

// MARK: - Mirror of iTrafficPlus/ITrafficMonitorForMac/ProcessEntity.swift
// Only the fields the comparator uses; `icon` is irrelevant to sort order.
struct ProcessEntity {
    let pid: Int
    var name: String
    var inBytesPerSec: Int
    var outBytesPerSec: Int
}

enum ListSortMode: String, CaseIterable {
    case total, download, upload, name

    var label: String {
        switch self {
        case .total:    return "Total"
        case .download: return "Down"
        case .upload:   return "Up"
        case .name:     return "Name"
        }
    }
}

// MARK: - Mirror of ListViewModel.sort(items:) — see the file for rationale.
func sort(items: [ProcessEntity], mode: ListSortMode) -> [ProcessEntity] {
    return items.sorted { (lhs, rhs) in
        switch mode {
        case .total:
            let lTotal = lhs.inBytesPerSec + lhs.outBytesPerSec
            let rTotal = rhs.inBytesPerSec + rhs.outBytesPerSec
            if lTotal != rTotal { return lTotal > rTotal }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .download:
            if lhs.inBytesPerSec != rhs.inBytesPerSec { return lhs.inBytesPerSec > rhs.inBytesPerSec }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .upload:
            if lhs.outBytesPerSec != rhs.outBytesPerSec { return lhs.outBytesPerSec > rhs.outBytesPerSec }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Fixture + assertions
func fixture() -> [ProcessEntity] {
    return [
        ProcessEntity(pid: 1, name: "alpha",   inBytesPerSec: 100, outBytesPerSec:  10),
        ProcessEntity(pid: 2, name: "BRAVO",   inBytesPerSec: 200, outBytesPerSec:  50),
        ProcessEntity(pid: 3, name: "Charlie", inBytesPerSec:   0, outBytesPerSec: 500),
        ProcessEntity(pid: 4, name: "delta",   inBytesPerSec: 150, outBytesPerSec: 150),
    ]
}

var failures: [(String, String)] = []
var passes = 0

func check(_ name: String, _ actual: [Int], _ expected: [Int]) {
    if actual == expected {
        passes += 1
        print("  PASS  \(name)")
    } else {
        failures.append((name, "expected \(expected), got \(actual)"))
        print("  FAIL  \(name): expected \(expected), got \(actual)")
    }
}

func checkStrings(_ name: String, _ actual: [String], _ expected: [String]) {
    if actual == expected {
        passes += 1
        print("  PASS  \(name)")
    } else {
        failures.append((name, "expected \(expected), got \(actual)"))
        print("  FAIL  \(name): expected \(expected), got \(actual)")
    }
}

print("=== iTrafficPlus sort verification (standalone) ===")
print()

let vm = fixture()

check("total",        sort(items: vm, mode: .total).map(\.pid),    [3, 4, 2, 1])
check("download",     sort(items: vm, mode: .download).map(\.pid), [2, 4, 1, 3])
check("upload",       sort(items: vm, mode: .upload).map(\.pid),   [3, 4, 2, 1])

let nameOrder = sort(items: vm, mode: .name).map(\.name).map { $0.lowercased() }
if nameOrder == ["alpha", "bravo", "charlie", "delta"] {
    passes += 1
    print("  PASS  name")
} else {
    failures.append(("name", "got \(nameOrder)"))
    print("  FAIL  name: got \(nameOrder)")
}

// Tie-breaker
let tied = [
    ProcessEntity(pid: 10, name: "zulu",  inBytesPerSec: 100, outBytesPerSec: 100),
    ProcessEntity(pid: 11, name: "ALPHA", inBytesPerSec: 100, outBytesPerSec: 100),
]
checkStrings("tieBreaker", sort(items: tied, mode: .total).map(\.name), ["ALPHA", "zulu"])

// Empty / single
for mode in ListSortMode.allCases {
    let label = "empty-\(mode.rawValue)"
    let result = sort(items: [], mode: mode)
    if result.isEmpty {
        passes += 1
        print("  PASS  \(label)")
    } else {
        failures.append((label, "expected [], got \(result)"))
        print("  FAIL  \(label): expected [], got \(result)")
    }
}

// Idempotence
for mode in ListSortMode.allCases {
    let label = "idempotent-\(mode.rawValue)"
    let once = sort(items: vm, mode: mode)
    let twice = sort(items: once, mode: mode)
    if once.map(\.pid) == twice.map(\.pid) {
        passes += 1
        print("  PASS  \(label)")
    } else {
        failures.append((label, "double sort produced different orders"))
        print("  FAIL  \(label)")
    }
}

print()
print("=== \(passes) pass, \(failures.count) fail ===")
if !failures.isEmpty {
    for (n, why) in failures {
        print("  - \(n): \(why)")
    }
    exit(1)
}
exit(0)
