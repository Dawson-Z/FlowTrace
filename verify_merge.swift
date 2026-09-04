//
//  verify_merge.swift
//  Standalone CLI verification for ListViewModel.mergeSameNameProcesses(_:).
//
//  Why this exists
//  ---------------
//  Same reasoning as verify_sort.swift: xcodebuild test is blocked by the
//  development sandbox (the .xcresult bundle writes to build/Logs/Test/,
//  which the sandbox denies). Running the unit tests from the CLI is not
//  possible from here, so this script embeds the exact merge logic and runs
//  the same fixtures ListViewModelMergeTests.swift describes.
//
//  Run:
//      swift verify_merge.swift
//
//  Exit code 0 = all pass, 1 = at least one failed.
//

import Foundation

// MARK: - Mirror of iTrafficPlus/ITrafficMonitorForMac/ProcessEntity.swift
struct ProcessEntity {
    var pid: Int
    var name: String
    var inBytesPerSec: Int
    var outBytesPerSec: Int
}

// MARK: - Mirror of ListViewModel.mergeSameNameProcesses(_:) — see the file.
func mergeSameNameProcesses(_ entities: [ProcessEntity]) -> [ProcessEntity] {
    var byName: [String: ProcessEntity] = [:]
    var order: [String] = []
    for e in entities {
        let key = e.name.lowercased()
        if var existing = byName[key] {
            existing.inBytesPerSec += e.inBytesPerSec
            existing.outBytesPerSec += e.outBytesPerSec
            existing.pid = min(existing.pid, e.pid)
            byName[key] = existing
        } else {
            order.append(key)
            byName[key] = e
        }
    }
    return order.compactMap { byName[$0] }
}

// MARK: - Helpers
var failures: [(String, String)] = []
var passes = 0

func entity(_ pid: Int, _ name: String, _ inB: Int, _ outB: Int) -> ProcessEntity {
    ProcessEntity(pid: pid, name: name, inBytesPerSec: inB, outBytesPerSec: outB)
}

func check(_ name: String, _ ok: Bool, _ why: String = "") {
    if ok {
        passes += 1
        print("  PASS  \(name)")
    } else {
        failures.append((name, why))
        print("  FAIL  \(name): \(why)")
    }
}

print("=== iTrafficPlus merge verification (standalone) ===")
print()

// 1. Same app (several PIDs) collapses into one row.
do {
    let input = [
        entity(86108, "Trae CN Helper", 1_000_000, 200_000),
        entity(86111, "Trae CN Helper", 100_000,  50_000),
        entity(86112, "Trae CN Helper", 100_000,  50_000),
    ]
    let merged = mergeSameNameProcesses(input)
    check("sameNameCollapses", merged.count == 1 &&
          merged[0].inBytesPerSec == 1_200_000 &&
          merged[0].outBytesPerSec == 300_000 &&
          merged[0].pid == 86108 &&
          merged[0].name == "Trae CN Helper",
          "got \(merged)")
}

// 2. Case-insensitive: "node"/"Node" are one row; first-seen spelling kept.
do {
    let input = [
        entity(1, "node", 100, 10),
        entity(2, "Node", 200, 20),
    ]
    let merged = mergeSameNameProcesses(input)
    check("caseInsensitiveMerge", merged.count == 1 &&
          merged[0].inBytesPerSec == 300 &&
          merged[0].outBytesPerSec == 30 &&
          merged[0].name == "node",
          "got \(merged)")
}

// 3. Distinct names are not merged.
do {
    let input = [
        entity(1, "Safari", 100, 10),
        entity(2, "Chrome", 200, 20),
    ]
    let merged = mergeSameNameProcesses(input)
    check("distinctNamesNotMerged", merged.count == 2, "got \(merged)")
}

// 4. Insertion order of first-seen names preserved.
do {
    let input = [
        entity(3, "Delta", 30, 3),
        entity(1, "Alpha", 10, 1),
        entity(2, "Bravo", 20, 2),
    ]
    let merged = mergeSameNameProcesses(input)
    let names = merged.map(\.name)
    check("preservesFirstSeenOrder", names == ["Delta", "Alpha", "Bravo"],
          "got \(names)")
}

// 5. Idempotent: re-merging an already-merged list is a no-op.
do {
    let input = [
        entity(86108, "Trae CN Helper", 1_000_000, 200_000),
        entity(86109, "Trae CN Helper", 100_000,  50_000),
        entity(1, "Safari", 100, 10),
    ]
    let once = mergeSameNameProcesses(input)
    let twice = mergeSameNameProcesses(once)
    check("idempotent",
          once.map(\.pid) == twice.map(\.pid) &&
          once.map(\.name) == twice.map(\.name),
          "once=\(once) twice=\(twice)")
}

// 6. Empty input yields empty output.
do {
    let merged = mergeSameNameProcesses([])
    check("empty", merged.isEmpty, "got \(merged)")
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
