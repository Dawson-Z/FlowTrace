//
//  HistoryHeatmapModel.swift
//  FlowTrace — Feature/History
//
//  Drives the standalone history window: resolves the selected time range
//  and interface-category filter into ms boundaries, asks HistoryPersistence
//  for the hour-bucketed heatmap, and publishes the cells.
//
//  Data-source rule: the grid always reads the per-interface *minute* table
//  (`interface_minute`), the same minute-cadence source the App-usage page
//  uses. With every category selected it sums all of them (= total external
//  traffic); unchecking a category excludes that interface from the grid.
//  Consequence of dropping the old totals-table path: the grid can only show
//  data from the milestone that introduced interface minute buckets onward,
//  so a database with older rows will render them as empty cells.
//

import Foundation

enum HeatmapRange: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days
    case custom

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .today:      return "Today"
        case .last7Days:  return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .custom:     return "Custom"
        }
    }
}

final class HistoryHeatmapModel: ObservableObject {

    @Published var range: HeatmapRange = .last7Days {
        didSet { reload() }
    }
    /// Bounds for `.custom`, interpreted as local calendar days.
    @Published var customFrom: Date = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date() {
        didSet { if range == .custom { reload() } }
    }
    @Published var customTo: Date = Date() {
        didSet { if range == .custom { reload() } }
    }
    /// Which interface categories to include. All selected = totals table.
    @Published var selectedCategories: Set<InterfaceCategory> = Set(InterfaceCategory.allCases) {
        didSet { reload() }
    }

    /// Hour-bucketed cells from the persistence layer (main queue).
    @Published private(set) var cells: [HeatmapCell] = []

    private var persistence: HistoryPersistence? { SharedStore.historyPersistence }

    func reload() {
        guard let persistence else { return }

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
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)

        // The heatmap reads the PER-INTERFACE minute table to show each
        // network interface's usage on a minute-cadence source (matching the
        // App usage page). With every category selected it sums all interface
        // categories (= total external traffic); unchecking a category
        // excludes that interface from the grid.
        let categories = selectedCategories.map(\.rawValue).sorted()
        persistence.interfaceMinuteHeatmap(fromMs: fromMs, toMs: toMs, categories: categories) { [weak self] cells in
            self?.cells = cells
        }
    }

    /// Export the current range's per-interface minute rows as CSV.
    func exportCSV() {
        guard let persistence else { return }
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
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        let fromBucket = Int((from.timeIntervalSince1970 + tz) / 60)
        let toBucket = Int((to.timeIntervalSince1970 + tz) / 60)
        persistence.exportInterfaceMinute(fromBucket: fromBucket, toBucket: toBucket) { rows in
            CSVExporter.save(csv: CSVExporter.interfaceCSV(rows), suggestedName: "interface-stats.csv")
        }
    }

    /// Local Date for a cell's absolute day index (days since 1970, local).
    func date(forDay day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day) * 86400
             - TimeInterval(TimeZone.current.secondsFromGMT()))
    }
}
