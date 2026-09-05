//
//  ProcessUsageModel.swift
//  iTrafficPlus — Feature/History
//
//  Backs the "App usage" tab of the history window: resolves the selected
//  HeatmapRange into local-minute bucket bounds, fetches SUM(bytes) per
//  process, and re-sorts locally on sort-mode change (event value, per the
//  @Published willSet rule in the pitfalls guide).
//

import Foundation
import Combine

final class ProcessUsageModel: ObservableObject {

    @Published var range: HeatmapRange = .last7Days {
        didSet { reload() }
    }
    @Published var customFrom: Date = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date() {
        didSet { if range == .custom { reload() } }
    }
    @Published var customTo: Date = Date() {
        didSet { if range == .custom { reload() } }
    }
    @Published var sortMode: ListSortMode = .total {
        didSet {
            // didSet runs *after* the write, so reading self.sortMode here is
            // safe (unlike a $prop sink).
            rows = Self.sort(rows: rows, mode: sortMode)
        }
    }

    @Published private(set) var rows: [ProcessUsageSummary] = []

    func reload() {
        guard let persistence = SharedStore.historyPersistence else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        let from: Date
        let to: Date
        switch range {
        case .today:
            from = today; to = tomorrow
        case .last7Days:
            from = calendar.date(byAdding: .day, value: -6, to: today) ?? today; to = tomorrow
        case .last30Days:
            from = calendar.date(byAdding: .day, value: -29, to: today) ?? today; to = tomorrow
        case .custom:
            from = calendar.startOfDay(for: customFrom)
            to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customTo)) ?? tomorrow
        }

        // Same local-ordinal convention as the aggregator's minute_bucket.
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        let fromBucket = Int((from.timeIntervalSince1970 + tz) / 60)
        let toBucket = Int((to.timeIntervalSince1970 + tz) / 60)

        persistence.processUsage(fromBucket: fromBucket, toBucket: toBucket) { [weak self] fetched in
            guard let self else { return }
            self.rows = Self.sort(rows: fetched, mode: self.sortMode)
        }
    }

    /// Pure value-in/value-out sort shared by didSet and the query callback
    /// (which must apply the mode it captured, not a possibly-stale read).
    static func sort(rows: [ProcessUsageSummary], mode: ListSortMode) -> [ProcessUsageSummary] {
        rows.sorted { lhs, rhs in
            switch mode {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .download:
                if lhs.inBytes != rhs.inBytes { return lhs.inBytes > rhs.inBytes }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .upload:
                if lhs.outBytes != rhs.outBytes { return lhs.outBytes > rhs.outBytes }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .total:
                let l = lhs.inBytes + lhs.outBytes
                let r = rhs.inBytes + rhs.outBytes
                if l != r { return l > r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
