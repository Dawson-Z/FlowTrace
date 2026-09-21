//
//  ProcessUsageAggregator.swift
//  FlowTrace — Feature/History
//
//  Turns the per-frame process rates into per-minute *byte* rows.
//
//  Why aggregate here: raw process frames would be ~1.3 M rows/day. One row
//  per (minute, process-name) is ~4 orders of magnitude smaller and still
//  answers "which app used how much over any range".
//
//  Byte accounting: each frame's rate (bytes/sec, already normalised) is in
//  effect for `interval` seconds, so a minute bucket's bytes = Σ(rate) ×
//  interval — exact for the *observed* part of the minute even when it is
//  shorter (app launch, interval change, app sleep). The ×interval happens
//  ONLY in flush; everything upstream stays in bytes/sec.
//
//  Grouping key is the lowercased process name, so a process that quits and
//  relaunches (new pid) still accumulates under one row, and same-name
//  helpers (Electron apps) merge — mirroring the popover's merge semantics.
//

import Foundation

final class ProcessUsageAggregator {

    struct Accumulated {
        var sumInBps = 0
        var sumOutBps = 0
        var firstName = ""
    }

    private let queue = DispatchQueue(label: "process-usage-aggregator", qos: .utility)
    private let persistence: () -> HistoryPersistence?

    /// Local-minute ordinal currently being accumulated.
    private var currentBucket = 0
    private var hasCurrentBucket = false
    private var accumulated: [String: Accumulated] = [:]
    /// Pids we have already accepted a frame for. nettop reports a *newly
    /// seen* process row as its cumulative-since-launch bytes (baseline 0),
    /// so the first frame of every pid must be dropped or app launches
    /// inject their lifetime traffic into the minute bucket.
    private var seenPids: Set<Int> = []

    init(persistence: @escaping () -> HistoryPersistence?) {
        self.persistence = persistence
    }

    /// Local-minute ordinal for an epoch-ms stamp (same convention as the
    /// table's `minute_bucket` column).
    static func bucket(of date: Date) -> Int {
        let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
        return Int((Int64(date.timeIntervalSince1970 * 1000) + tzMs) / 60000)
    }

    /// Feed one frame of normalised process rates. Cheap; state protected by
    /// the internal serial queue.
    func feed(entities: [ProcessEntity], interval: Int, now: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            let bucket = Self.bucket(of: now)
            if self.hasCurrentBucket, bucket != self.currentBucket {
                // The previous minute is complete — write it out, then start
                // the new bucket. The old window's rows are flushed with the
                // interval that was in effect for them (passed by the caller).
                self.flushLocked(interval: interval)
            }
            self.currentBucket = bucket
            self.hasCurrentBucket = true
            for entity in entities {
                // Drop the first frame of every NEW pid: nettop reports it as
                // cumulative-since-launch, not as a delta (app launches would
                // otherwise inject their lifetime traffic into the minute).
                guard self.seenPids.contains(entity.pid) else {
                    self.seenPids.insert(entity.pid)
                    continue
                }
                guard entity.inBytesPerSec != 0 || entity.outBytesPerSec != 0 else { continue }
                let key = entity.name.lowercased()
                var acc = self.accumulated[key] ?? Accumulated()
                if acc.firstName.isEmpty { acc.firstName = entity.name }
                acc.sumInBps += entity.inBytesPerSec
                acc.sumOutBps += entity.outBytesPerSec
                self.accumulated[key] = acc
            }
        }
    }

    /// Caller holds `queue`.
    private func flushLocked(interval: Int) {
        guard interval > 0, !accumulated.isEmpty,
              let persistence = persistence() else {
            // CRITICAL: clear the accumulator even when the write is skipped —
            // leaving it intact turned every later flush into "sum since the
            // beginning" (the reported "results far too large" bug).
            accumulated.removeAll()
            return
        }
        let rows = accumulated.map { key, acc in
            ProcessUsageFlushRow(
                minuteBucket: currentBucket,
                name: acc.firstName,
                nameKey: key,
                inBytes: acc.sumInBps * interval,
                outBytes: acc.sumOutBps * interval
            )
        }
        persistence.appendProcessUsage(rows)
        accumulated.removeAll()
    }
}
