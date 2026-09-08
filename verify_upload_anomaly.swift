//
//  verify_upload_anomaly.swift
//  Standalone CLI verification for UploadAnomalyMonitor's decision logic.
//
//  Mirrors media/decide + the per-process state machine:
//    - median of rolling baseline (even/odd count)
//    - spike = baseline(≥5 samples) && median>0 && upload≥median×mult && upload≥minBytes
//    - cold start: a thin baseline never fires
//    - zero upload resets the consecutive counter (burst ended)
//    - cooldown suppresses repeat notifications for the same process
//

import Foundation

var failures: [(String, String)] = []
var passes = 0

func check(_ name: String, _ ok: Bool, _ why: String = "") {
    if ok { passes += 1; print("  PASS  \(name)") }
    else { failures.append((name, why)); print("  FAIL  \(name): \(why)") }
}

// Mirror: median
func median(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted(); let m = s.count / 2
    return s.count % 2 == 0 ? (s[m-1] + s[m]) / 2 : s[m]
}

// Mirror: decide
func decide(upload: Int, baseline: [Int], multiplier: Int, minBytes: Int) -> (isSpike: Bool, t: Int) {
    let med = median(baseline)
    let t = med * multiplier
    let spike = baseline.count >= 5 && med > 0 && upload >= t && upload >= minBytes
    return (spike && t > 0, t)
}

// State machine mirror: returns whether to notify this frame (after 3 consecutive spikes + cooldown).
final class Sim {
    var baseline: [Int] = []
    var consecutive = 0
    var lastNotifiedAt: Date?
    var notified = 0
    let minBytes: Int
    let multiplier: Int
    init(multiplier: Int, minBytes: Int) { self.multiplier = multiplier; self.minBytes = minBytes }

    func feed(upload: Int, now: Date) {
        if upload <= 0 { consecutive = 0; return }
        baseline.append(upload)
        if baseline.count > 15 { baseline.removeFirst() }
        let d = decide(upload: upload, baseline: baseline, multiplier: multiplier, minBytes: minBytes)
        if d.isSpike {
            consecutive += 1
            if consecutive >= 3 {
                if lastNotifiedAt == nil || now.timeIntervalSince(lastNotifiedAt!) >= 1800 {
                    notified += 1
                    lastNotifiedAt = now
                    consecutive = 0
                }
            }
        } else {
            consecutive = 0
        }
    }
}

print("=== iTrafficPlus upload anomaly verification (standalone) ===")
print()

// 1. Median.
check("median-odd", median([2, 9, 4]) == 4)
check("median-even", median([2, 9, 4, 7]) == 5)  // (4+7)/2 = 5
check("median-empty", median([]) == 0)

// 2. Spike conditions.
let baseline = [100, 120, 110, 90, 105, 115]      // median 107-ish
let med = median(baseline)
check("spike-high", decide(upload: med*8+1, baseline: baseline, multiplier: 8, minBytes: 1).isSpike)
check("no-spike-low-upload", !decide(upload: med*3, baseline: baseline, multiplier: 8, minBytes: 1).isSpike)
check("no-spike-below-abs", !decide(upload: med*8+1, baseline: baseline, multiplier: 8, minBytes: 1_000_000).isSpike)

// 3. Cold start: <5 samples never fires even if huge.
check("cold-start-no-fire", !decide(upload: 999_999, baseline: [100, 100, 100, 100], multiplier: 8, minBytes: 1).isSpike)
check("zero-median-no-fire", !decide(upload: 999_999, baseline: [0, 0, 0, 0, 0], multiplier: 8, minBytes: 1).isSpike)

// 4. State machine: 3 consecutive spikes → notify once; cooldown suppresses.
do {
    let sim = Sim(multiplier: 8, minBytes: 1)
    var t = Date(timeIntervalSince1970: 1_700_000_000)
    // Build baseline with 5 frames of ~100.
    for _ in 0..<15 { sim.feed(upload: 100, now: t); t += 2 }
    // Three consecutive spikes.
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    check("three-spikes-notify", sim.notified == 1, "notified=\(sim.notified)")
    // Two more spikes within cooldown (30 min) → no new notify.
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    check("cooldown-suppresses", sim.notified == 1, "notified=\(sim.notified)")
    // After cooldown elapses → notifies again.
    t += 1900  // ~31 min later
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    check("cooldown-ree-lapse-notify", sim.notified == 2, "notified=\(sim.notified)")
}

// 5. Zero upload resets the consecutive counter.
do {
    let sim = Sim(multiplier: 8, minBytes: 1)
    var t = Date(timeIntervalSince1970: 1_700_000_000)
    for _ in 0..<15 { sim.feed(upload: 100, now: t); t += 2 }
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 0, now: t); t += 2       // burst interrupted
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    sim.feed(upload: 1000, now: t); t += 2
    check("zero-resets-counter", sim.notified == 1, "notified=\(sim.notified) (burst reset means only the later 3 count)")
}

print()
print("=== \(passes) pass, \(failures.count) fail ===")
if !failures.isEmpty {
    for (n, why) in failures { print("  - \(n): \(why)") }
    exit(1)
}
exit(0)
