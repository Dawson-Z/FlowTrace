//
//  UsageAggregator.swift
//  iTrafficPlus — Feature/Usage
//
//  Single source of truth for "bytes used in a period" (today / this week /
//  this month). Reads the `process_usage` table — the byte-level store — so:
//    - the numbers survive restarts,
//    - they are independent of the sample interval (1/2/5 s),
//    - they agree with the App-usage tab by construction.
//
//  Throttling: Network.handleFrame calls tick() every frame, but a db query
//  runs at most every `minFetchInterval` seconds. Consumers (quota monitor,
//  status bar) observe the @Published values.
//

import Foundation
import Combine

struct UsageBytes: Equatable {
    var inBytes = 0
    var outBytes = 0
    var total: Int { inBytes + outBytes }
}

final class UsageAggregator: ObservableObject {

    @Published private(set) var today = UsageBytes()
    @Published private(set) var week = UsageBytes()
    @Published private(set) var month = UsageBytes()

    /// Called by the Settings "Clear data" action to zero the in-memory
    /// period totals (the disk tables are cleared separately).
    func reset() {
        today = UsageBytes()
        week = UsageBytes()
        month = UsageBytes()
        lastFetchAt = Date.distantPast
    }

    private let queue = DispatchQueue(label: "usage-aggregator", qos: .utility)
    private var lastFetchAt = Date.distantPast
    private let minFetchInterval: TimeInterval

    init(minFetchInterval: TimeInterval = 15) {
        self.minFetchInterval = minFetchInterval
    }

    /// Local-minute ordinal (same convention as `process_usage.minute_bucket`).
    static func bucket(of date: Date) -> Int {
        let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
        return Int((Int64(date.timeIntervalSince1970 * 1000) + tzMs) / 60000)
    }

    /// Called from the frame path; throttled.
    func tick() {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            guard now.timeIntervalSince(self.lastFetchAt) >= self.minFetchInterval else { return }
            self.lastFetchAt = now

            guard let persistence = SharedStore.historyPersistence else { return }
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: now)
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? todayStart

            func fetch(_ from: Date, _ publish: @escaping (UsageBytes) -> Void) {
                persistence.usageBytes(fromBucket: Self.bucket(of: from), toBucket: Self.bucket(of: now) + 1) { usage in
                    DispatchQueue.main.async { publish(usage) }
                }
            }
            fetch(todayStart) { self.today = $0 }
            fetch(weekStart) { self.week = $0 }
            fetch(monthStart) { self.month = $0 }
        }
    }
}
