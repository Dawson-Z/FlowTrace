//
//  verify_history.swift
//  Standalone CLI verification for the heatmap data pipeline.
//
//  Same rationale as verify_sort/verify_merge: xcodebuild test cannot run
//  inside the development sandbox, so this script mirrors the *pure logic*
//  of the heatmap pipeline and asserts it against fixtures:
//
//    1. Interface delta → rate normalisation (divide by interval, once)
//    2. Local-hour bucketing: (ts + tzOffsetMs) / 3600000 → day/hour
//    3. AVG aggregation per (day, hour) bucket
//    4. Category filter (subset query only includes matching rows)
//    5. Empty range / no data → empty cells
//    6. Display-layer volume conversion (avg rate × 3600 s)
//
//  Run:
//      swift verify_history.swift
//
//  Exit code 0 = all pass, 1 = at least one failed.
//

import Foundation

// MARK: - Mirrors of the production logic

/// Network.makeInterfaceMonitor: window delta → bytes/sec, single divide.
func normalise(delta: Int, interval: Int) -> Int {
    delta / interval
}

/// HistoryPersistence.heatmapSync: local-hour bucket of an epoch-ms stamp.
func bucket(of tsMs: Int64, tzSeconds: Int) -> Int {
    Int((tsMs + Int64(tzSeconds) * 1000) / 3600000)
}

struct Row {
    let tsMs: Int64
    let category: String
    let inBps: Int
    let outBps: Int
}

/// Aggregation mirror: filter by categories (nil = no filter), bucket, AVG.
func aggregate(rows: [Row], tzSeconds: Int, categories: [String]?) -> [Int: (inAvg: Double, outAvg: Double)] {
    var buckets: [Int: (sumIn: Int, sumOut: Int, count: Int)] = [:]
    for row in rows {
        if let categories, !categories.contains(row.category) { continue }
        let key = bucket(of: row.tsMs, tzSeconds: tzSeconds)
        var b = buckets[key] ?? (0, 0, 0)
        b.sumIn += row.inBps; b.sumOut += row.outBps; b.count += 1
        buckets[key] = b
    }
    return buckets.mapValues { (Double($0.sumIn) / Double($0.count), Double($0.sumOut) / Double($0.count)) }
}

// MARK: - Harness

var failures: [(String, String)] = []
var passes = 0

func check(_ name: String, _ ok: Bool, _ why: String = "") {
    if ok {
        passes += 1
        print("  PASS  \(name)")
    } else {
        failures.append((name, why))
        print("  FAIL  \(name): \(why)")
    }
}

print("=== iTrafficPlus history heatmap verification (standalone) ===")
print()

let TZ = 8 * 3600  // UTC+8, mirrors Asia/Shanghai

// Local 2026-09-04 00:00 UTC+8 == 2026-09-03T16:00:00Z.
let localMidnightMs: Int64 = Int64(Date(timeIntervalSince1970: 0).timeIntervalSince1970) // unused guard
let day0Hour0 = Int64((1788516000)) * 1000  // 2026-09-04T16:00:00Z? — computed via calendar below instead
// Compute precisely with Foundation to avoid hand-derived epoch constants:
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(secondsFromGMT: TZ)!
let midnight = cal.startOfDay(for: Date(timeIntervalSince1970: 1_788_516_000))
let h0 = Int64(midnight.timeIntervalSince1970) * 1000
let h0Bucket = bucket(of: h0, tzSeconds: TZ)
let h5 = h0 + 5 * 3600 * 1000
let h23 = h0 + 23 * 3600 * 1000
let nextDayH0 = h0 + 24 * 3600 * 1000

// 1. Normalisation: 4000 bytes over a 2 s window → 2000 B/s; over 1 s → 4000.
check("normalise-2s", normalise(delta: 4000, interval: 2) == 2000)
check("normalise-1s", normalise(delta: 4000, interval: 1) == 4000)
check("normalise-5s", normalise(delta: 4000, interval: 5) == 800)

// 2. Bucketing: local midnight lands on hour 0 of its day; +23 h on hour 23 same day.
check("bucket-midnight-hour0", h0Bucket % 24 == 0, "got \(h0Bucket % 24)")
check("bucket-23h", bucket(of: h23, tzSeconds: TZ) % 24 == 23, "got \(bucket(of: h23, tzSeconds: TZ) % 24)")
check("bucket-same-day", bucket(of: h23, tzSeconds: TZ) / 24 == h0Bucket / 24)
check("bucket-next-day", bucket(of: nextDayH0, tzSeconds: TZ) / 24 == h0Bucket / 24 + 1)

// 3+4. Aggregation + category filter.
let rows: [Row] = [
    Row(tsMs: h0 + 1000,          category: "Wi-Fi", inBps: 1000, outBps: 100),
    Row(tsMs: h0 + 2000,          category: "Wi-Fi", inBps: 3000, outBps: 300),
    Row(tsMs: h0 + 3000,          category: "Wired", inBps: 2000, outBps: 200),
    Row(tsMs: h0 + 3600_000 + 1,  category: "Local Direct", inBps: 9000, outBps: 900), // next local hour
    Row(tsMs: h0 + 3600_000 + 2,  category: "Local Direct", inBps: 1000, outBps: 100),
]

let all = aggregate(rows: rows, tzSeconds: TZ, categories: nil)
check("agg-all-hour0-count", all[h0Bucket]?.inAvg == (1000 + 3000 + 2000) / 3.0,
      "got \(String(describing: all[h0Bucket]?.inAvg))")

let wifiOnly = aggregate(rows: rows, tzSeconds: TZ, categories: ["Wi-Fi"])
check("agg-filter-wifi-hour0", wifiOnly[h0Bucket]?.inAvg == 2000, "got \(String(describing: wifiOnly[h0Bucket]?.inAvg))")
check("agg-filter-excludes-other-hours", wifiOnly[h0Bucket + 1] == nil)

let ldOnly = aggregate(rows: rows, tzSeconds: TZ, categories: ["Local Direct"])
check("agg-filter-ld-hour1", ldOnly[h0Bucket + 1]?.inAvg == 5000, "got \(String(describing: ldOnly[h0Bucket + 1]?.inAvg))")
check("agg-filter-ld-empty-hour0", ldOnly[h0Bucket] == nil, "excluded category must not leak into bucket")

// 5. Empty input → empty aggregation.
check("agg-empty", aggregate(rows: [], tzSeconds: TZ, categories: nil).isEmpty)

// 6. Display conversion: mean rate × 3600 s → hour volume.
let avg: Double = 500_000  // 500 KB/s mean over the hour
check("volume-conversion", Int(avg * 3600) == 1_800_000_000, "500 KB/s hour should read ≈1.8 GB")

// 7. Cross-midnight sanity: a stamp 1 s before local midnight belongs to the *previous* day's hour 23.
let beforeMidnight = h0 - 1000
check("bucket-before-midnight", bucket(of: beforeMidnight, tzSeconds: TZ) % 24 == 23
                               && bucket(of: beforeMidnight, tzSeconds: TZ) / 24 == h0Bucket / 24 - 1)

print()
print("=== \(passes) pass, \(failures.count) fail ===")
if !failures.isEmpty {
    for (n, why) in failures {
        print("  - \(n): \(why)")
    }
    exit(1)
}
exit(0)
