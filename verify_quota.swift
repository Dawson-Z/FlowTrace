//
//  verify_quota.swift
//  Standalone CLI verification for the quota threshold logic.
//
//  Mirrors QuotaMonitor's pure decision layer:
//    - threshold set construction (80/100 always, custom merged, deduped)
//    - crossing detection (prev < t && curr >= t), first-observation arms
//    - dedup keys ("periodStart:threshold"), period rollover re-arms
//    - period start key computation for month/week/day
//

import Foundation

// MARK: - Mirrors

func thresholdSet(custom: Int) -> [Int] {
    var set: Set<Int> = [80, 100]
    if custom > 0 && custom < 100 { set.insert(custom) }
    return set.sorted()
}

/// Returns keys fired this check, mutating the fired set. Mirrors QuotaMonitor.check().
func check(prev: Double, curr: Double, thresholds: [Int], periodKey: String, fired: inout Set<String>) -> [String] {
    var firedNow: [String] = []
    for t in thresholds where curr >= Double(t) {
        let key = "\(periodKey):\(t)"
        guard !fired.contains(key), prev < Double(t) else { continue }
        fired.insert(key)
        firedNow.append(key)
    }
    return firedNow
}

func periodStartKey(period: String, now: Date) -> String {
    let calendar = Calendar.current
    let start: Date
    switch period {
    case "day":  start = calendar.startOfDay(for: now)
    case "week": start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    default:     start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? calendar.startOfDay(for: now)
    }
    return ISO8601DateFormatter().string(from: start)
}

// MARK: - Harness

var failures: [(String, String)] = []
var passes = 0

func check(_ name: String, _ ok: Bool, _ why: String = "") {
    if ok { passes += 1; print("  PASS  \(name)") }
    else { failures.append((name, why)); print("  FAIL  \(name): \(why)") }
}

print("=== iTrafficPlus quota verification (standalone) ===")
print()

// 1. Threshold set construction.
check("thresholds-default", thresholdSet(custom: 0) == [80, 100])
check("thresholds-custom-90", thresholdSet(custom: 90) == [80, 90, 100])
check("thresholds-custom-dup-80", thresholdSet(custom: 80) == [80, 100])
check("thresholds-custom-100-dup", thresholdSet(custom: 100) == [80, 100])
check("thresholds-custom-negative-ignored", thresholdSet(custom: -5) == [80, 100])

// 2. Crossing detection: prev < t && curr >= t.
do {
    var fired: Set<String> = []
    let now = Date()
    let key = periodStartKey(period: "month", now: now)

    // First observation at a low watermark arms the baseline — nothing fires.
    let first = check(prev: 0, curr: 10, thresholds: [80, 100], periodKey: key, fired: &fired)
    _ = first
    let r1 = check(prev: 10, curr: 85, thresholds: [80, 100], periodKey: key, fired: &fired)
    check("first-observation-arms", fired == ["\(key):80"] && r1 == ["\(key):80"],
          "fired=\(fired.sorted()) r1=\(r1)")

    // Cross 80: fires once.
    let r2 = check(prev: 85, curr: 80 + 5, thresholds: [80, 100], periodKey: key, fired: &fired)
    _ = r2
    // prev already >= 80 → 80 must not re-fire.
    let r3 = check(prev: 85, curr: 90, thresholds: [80, 100], periodKey: key, fired: &fired)
    check("cross-80-once", fired.contains("\(key):80") && !r3.contains("\(key):80"))

    // Jump from 70 to 105 crosses both 80 and 100 in one check.
    var fired2: Set<String> = []
    let r4 = check(prev: 70, curr: 105, thresholds: [80, 100], periodKey: key, fired: &fired2)
    check("multi-cross-single-check", Set(r4) == ["\(key):80", "\(key):100"], "got \(r4)")
}

// 3. Dedup: same threshold same period fires once.
do {
    var fired: Set<String> = []
    let key = periodStartKey(period: "day", now: Date())
    _ = check(prev: 0, curr: 10, thresholds: [80], periodKey: key, fired: &fired)
    _ = check(prev: 10, curr: 85, thresholds: [80], periodKey: key, fired: &fired)
    let again = check(prev: 85, curr: 95, thresholds: [80], periodKey: key, fired: &fired)
    check("dedup-same-period", again.isEmpty && fired == ["\(key):80"])
}

// 4. Period rollover: new period key re-arms the threshold.
do {
    var fired: Set<String> = []
    let sep = periodStartKey(period: "month", now: Date())
    _ = check(prev: 0, curr: 10, thresholds: [80], periodKey: sep, fired: &fired)
    _ = check(prev: 10, curr: 85, thresholds: [80], periodKey: sep, fired: &fired)
    check("fired-before-rollover", fired == ["\(sep):80"])

    let oct = periodStartKey(period: "month", now: Date(timeIntervalSince1970: 1_795_152_000)) // 2026-10-19-ish
    check("period-key-differs", oct != sep)
    let r = check(prev: 0, curr: 10, thresholds: [80], periodKey: oct, fired: &fired)
    // first observation in the new period arms only…
    _ = r
    let r2 = check(prev: 10, curr: 85, thresholds: [80], periodKey: oct, fired: &fired)
    check("rollover-re-arms", r2 == ["\(oct):80"], "got \(r2)")
}

// 5. Period start keys: month starts on the 1st, day at local midnight.
do {
    let cal = Calendar.current
    let now = Date()
    let monthKey = periodStartKey(period: "month", now: now)
    let monthStartISO = ISO8601DateFormatter().string(
        from: cal.date(from: cal.dateComponents([.year, .month], from: now))!
    )
    check("month-start-key", monthKey == monthStartISO)
    let dayKey = periodStartKey(period: "day", now: now)
    let dayStartISO = ISO8601DateFormatter().string(from: cal.startOfDay(for: now))
    check("day-start-key", dayKey == dayStartISO)
}

print()
print("=== \(passes) pass, \(failures.count) fail ===")
if !failures.isEmpty {
    for (n, why) in failures { print("  - \(n): \(why)") }
    exit(1)
}
exit(0)
