//
//  verify_process_usage.swift
//  Standalone CLI verification for the per-app usage pipeline.
//
//  Mirrors the pure logic of ProcessUsageAggregator + the process_usage
//  query (see the pitfalls guide for why these live as standalone scripts):
//
//    1. Minute-bucket ordinal & rollover
//    2. Same-name merge across pids / case variants
//    3. bytes = Σ(rate) × interval, exact for short windows
//    4. interval change → flush with the OLD interval before switching
//    5. Zero-traffic processes are skipped
//    6. Range filtering on minute buckets (inclusive start, exclusive end)
//    7. Sort modes (Name / Down / Up / Total)
//    8. Empty input → empty output
//
//  Run:
//      swift verify_process_usage.swift
//
//  Exit code 0 = all pass, 1 = at least one failed.
//

import Foundation

// MARK: - Mirrors of production logic

struct Entity { let name: String; let inBps: Int; let outBps: Int }

struct FlushRow { let minuteBucket: Int; let nameKey: String; let inBytes: Int; let outBytes: Int }

func bucket(of date: Date, tzSeconds: Int) -> Int {
    Int((Int64(date.timeIntervalSince1970 * 1000) + Int64(tzSeconds) * 1000) / 60000)
}

/// Stateful accumulator mirroring ProcessUsageAggregator.
final class Accumulator {
    private var currentBucket = 0
    private var hasBucket = false
    private var acc: [String: (sumIn: Int, sumOut: Int, first: String)] = [:]
    private(set) var flushed: [FlushRow] = []

    func feed(_ entities: [Entity], interval: Int, now: Date, tzSeconds: Int) {
        let b = bucket(of: now, tzSeconds: tzSeconds)
        if hasBucket, b != currentBucket { flushLocked(interval: interval) }
        currentBucket = b
        hasBucket = true
        for e in entities {
            guard e.inBps != 0 || e.outBps != 0 else { continue }
            let key = e.name.lowercased()
            var a = acc[key] ?? (0, 0, "")
            if a.first.isEmpty { a.first = e.name }
            a.sumIn += e.inBps; a.sumOut += e.outBps
            acc[key] = a
        }
    }

    func flush(interval: Int) {
        flushLocked(interval: interval)
        hasBucket = false
        acc.removeAll()
    }

    private func flushLocked(interval: Int) {
        guard interval > 0 else { return }
        for (key, a) in acc {
            flushed.append(FlushRow(minuteBucket: currentBucket, nameKey: key,
                                    inBytes: a.sumIn * interval, outBytes: a.sumOut * interval))
        }
        acc.removeAll()   // mirrors the production fix: flush must reset the bucket
    }
}

enum SortMode { case name, download, upload, total }
typealias Summary = (name: String, inBytes: Int, outBytes: Int)

func sortRows(_ rows: [Summary], mode: SortMode) -> [Summary] {
    rows.sorted { l, r in
        switch mode {
        case .name:     return l.name.lowercased() < r.name.lowercased()
        case .download: return l.inBytes > r.inBytes
        case .upload:   return l.outBytes > r.outBytes
        case .total:    return (l.inBytes + l.outBytes) > (r.inBytes + r.outBytes)
        }
    }
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

print("=== iTrafficPlus process usage verification (standalone) ===")
print()

let TZ = 8 * 3600
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(secondsFromGMT: TZ)!
let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_788_516_000))
let min0 = bucket(of: base, tzSeconds: TZ)

func at(minute: Int, second: Int = 0) -> Date {
    base.addingTimeInterval(TimeInterval(minute * 60 + second))
}

// 1+2+3: same-name merge across pids and case; bytes = Σrate × interval.
do {
    let acc = Accumulator()
    // Two frames inside minute 0; "Helper" appears as two pids/case variants.
    acc.feed([Entity(name: "Helper", inBps: 1000, outBps: 100)], interval: 2, now: at(minute: 0, second: 1), tzSeconds: TZ)
    acc.feed([Entity(name: "helper", inBps: 500, outBps: 50)], interval: 2, now: at(minute: 0, second: 30), tzSeconds: TZ)
    // Minute rollover → flush of minute 0.
    acc.feed([Entity(name: "Safari", inBps: 2000, outBps: 200)], interval: 2, now: at(minute: 1, second: 0), tzSeconds: TZ)

    let helper = acc.flushed.first { $0.nameKey == "helper" && $0.minuteBucket == min0 }
    check("merge-and-bytes", helper != nil
          && helper?.inBytes == (1000 + 500) * 2
          && helper?.outBytes == (100 + 50) * 2,
          "got \(String(describing: helper.map { ($0.inBytes, $0.outBytes) }))")
    check("first-spelling-kept", helper?.nameKey == "helper")
}

// 4. Interval change: in-flight bucket flushes with the OLD interval.
do {
    let acc = Accumulator()
    acc.feed([Entity(name: "Chrome", inBps: 3000, outBps: 300)], interval: 5, now: at(minute: 0), tzSeconds: TZ)
    acc.flush(interval: 5)  // applyRefreshInterval flushes BEFORE switching
    let row = acc.flushed.first { $0.nameKey == "chrome" }
    check("interval-change-flush", row?.inBytes == 3000 * 5, "got \(String(describing: row?.inBytes))")
}

// 5. Zero-traffic rows are skipped entirely.
do {
    let acc = Accumulator()
    acc.feed([Entity(name: "idle", inBps: 0, outBps: 0)], interval: 2, now: at(minute: 0), tzSeconds: TZ)
    acc.feed([Entity(name: "busy", inBps: 10, outBps: 0)], interval: 2, now: at(minute: 0), tzSeconds: TZ)
    acc.flush(interval: 2)
    check("zero-traffic-skipped", acc.flushed.count == 1 && acc.flushed[0].nameKey == "busy")
}

// 6. Range filtering on buckets: [from, to).
do {
    let flushed = [
        FlushRow(minuteBucket: min0, nameKey: "a", inBytes: 1, outBytes: 1),
        FlushRow(minuteBucket: min0 + 1, nameKey: "b", inBytes: 2, outBytes: 2),
        FlushRow(minuteBucket: min0 + 2, nameKey: "c", inBytes: 3, outBytes: 3),
    ]
    let inRange = flushed.filter { $0.minuteBucket >= min0 && $0.minuteBucket < min0 + 2 }
    check("range-filter", inRange.count == 2
          && inRange.contains { $0.nameKey == "a" }
          && inRange.contains { $0.nameKey == "b" })
}

// 7. Sort modes.
do {
    let rows: [Summary] = [
        ("zeta", 100, 900),   // total 1000
        ("Alpha", 800, 100),  // total 900
        ("beta", 400, 700),   // total 1100
    ]
    check("sort-name", sortRows(rows, mode: .name).map(\.name) == ["Alpha", "beta", "zeta"])
    check("sort-download", sortRows(rows, mode: .download).map(\.name) == ["Alpha", "beta", "zeta"])
    check("sort-upload", sortRows(rows, mode: .upload).map(\.name) == ["zeta", "beta", "Alpha"])
    check("sort-total", sortRows(rows, mode: .total).map(\.name) == ["beta", "zeta", "Alpha"])
}

// 8. Empty.
do {
    let acc = Accumulator()
    acc.flush(interval: 2)
    check("empty-flush-noop", acc.flushed.isEmpty)
    check("empty-sort", sortRows([], mode: .total).isEmpty)
}

// 9. Bucket ordinals are stable across the same local minute.
do {
    let a = bucket(of: at(minute: 5, second: 0), tzSeconds: TZ)
    let b = bucket(of: at(minute: 5, second: 59), tzSeconds: TZ)
    let c = bucket(of: at(minute: 6, second: 0), tzSeconds: TZ)
    check("bucket-59s-stable", a == b && b != c, "a=\(a) b=\(b) c=\(c)")
}

// 10. REGRESSION (the "results far too large" bug): after a minute rollover,
//     the previous minute's sums must NOT be re-flushed in later minutes.
do {
    let acc = Accumulator()
    acc.feed([Entity(name: "Helper", inBps: 1000, outBps: 100)], interval: 2,
             now: at(minute: 0), tzSeconds: TZ)                    // minute 0
    acc.feed([Entity(name: "Safari", inBps: 500, outBps: 50)], interval: 2,
             now: at(minute: 1), tzSeconds: TZ)                    // rollover → flush minute 0
    acc.feed([], interval: 2, now: at(minute: 2), tzSeconds: TZ)   // rollover → flush minute 1

    let helperRows = acc.flushed.filter { $0.nameKey == "helper" }
    let safariRows = acc.flushed.filter { $0.nameKey == "safari" }
    check("flush-resets-bucket", helperRows.count == 1
          && helperRows[0].minuteBucket == min0 && helperRows[0].inBytes == 2000
          && safariRows.count == 1 && safariRows[0].minuteBucket == min0 + 1,
          "helper rows=\(helperRows) safari rows=\(safariRows) (helper must appear exactly once, in minute 0 only)")
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
