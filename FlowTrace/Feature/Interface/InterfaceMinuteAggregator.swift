//
//  InterfaceMinuteAggregator.swift
//  FlowTrace — Feature/Interface
//
//  Rolls per-frame interface snapshots into local-minute buckets and writes
//  them to `interface_minute`, mirroring `ProcessUsageAggregator`. This is the
//  minute-cadence source the history window's network heatmap reads, so it
//  stays consistent with the App-usage page (both minute-bucket persisted).
//

import Foundation

final class InterfaceMinuteAggregator {
    private var currentBucket: Int = -1
    private var accumulated: [String: (inBytes: Int, outBytes: Int)] = [:]

    /// Accumulate one interface snapshot into the current local minute
    /// bucket. On a bucket change the finished minute is flushed to the
    /// `interface_minute` table so the history window stays minute-cadenced.
    func feed(_ snapshot: InterfaceSnapshot, now: Date, persistence: HistoryPersistence?) {
        let bucket = Self.minuteBucket(now)
        if bucket != currentBucket {
            flush(persistence: persistence)
            currentBucket = bucket
        }
        for (cat, inBytes) in snapshot.bytesIn {
            let k = cat.rawValue
            var v = accumulated[k] ?? (inBytes: 0, outBytes: 0)
            v.inBytes += inBytes
            accumulated[k] = v
        }
        for (cat, outBytes) in snapshot.bytesOut {
            let k = cat.rawValue
            var v = accumulated[k] ?? (inBytes: 0, outBytes: 0)
            v.outBytes += outBytes
            accumulated[k] = v
        }
    }

    private func flush(persistence: HistoryPersistence?) {
        defer { accumulated = [:] }
        guard currentBucket >= 0, !accumulated.isEmpty, let persistence else { return }
        let rows = accumulated.map {
            (minuteBucket: currentBucket, category: $0.key, inBytes: $0.value.inBytes, outBytes: $0.value.outBytes)
        }
        persistence.appendInterfaceMinute(rows)
    }

    /// Drop any in-flight minute (Settings "Clear data").
    func reset() {
        currentBucket = -1
        accumulated = [:]
    }

    /// Local minute ordinal — same convention as `ProcessUsageAggregator.bucket`,
    /// so both minute tables align on the same bucket boundaries.
    static func minuteBucket(_ date: Date) -> Int {
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        return Int((date.timeIntervalSince1970 + tz) / 60)
    }
}
