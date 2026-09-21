//
//  AlertLogView.swift
//  FlowTrace — Feature/History
//
//  "Alert log" tab of the history window: fired per-process traffic alerts.
//  One row = one alert record (time, process, direction, today's bytes, the
//  7-day daily median it was judged against, and the resulting factor). A
//  range filter (today / 7d / 30d / custom / all) narrows the window;
//  "custom" reveals the date-bounds row like the other tabs. The column
//  headers double as sort controls (newest first by default).
//

import SwiftUI

/// Range options for the alert log. Distinct from `HeatmapRange` because it
/// also offers "all" (the alert log is small and unbounded display is fine).
enum AlertRange: String, CaseIterable, Identifiable {
    case all
    case today
    case last7Days
    case last30Days
    case custom

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .all:        return "All"
        case .today:      return "Today"
        case .last7Days:  return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .custom:     return "Custom"
        }
    }
}

/// Sortable columns of the alert log. `time` is the default and matches the
/// query's own order (newest first), so an untouched tab reads exactly as it
/// did before the headers became sort controls.
enum AlertSortMode: String, CaseIterable {
    case time, name, direction, today, median, factor
}

final class AlertLogModel: ObservableObject {
    @Published var range: AlertRange = .all {
        didSet { reload() }
    }
    @Published var customFrom: Date = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date() {
        didSet { if range == .custom { reload() } }
    }
    @Published var customTo: Date = Date() {
        didSet { if range == .custom { reload() } }
    }
    @Published var sortMode: AlertSortMode = .time {
        didSet {
            // didSet runs *after* the write, so reading self.sortMode here is
            // safe (unlike a $prop sink). Re-sorting in memory keeps a header
            // click instant — no round trip to SQLite.
            records = Self.sort(records: records, mode: sortMode)
        }
    }

    @Published private(set) var records: [AlertRecord] = []

    func reload() {
        guard let persistence = SharedStore.historyPersistence else { return }
        persistence.alertRecords(fromMs: Self.fromMs(range: range, customFrom: customFrom, customTo: customTo)) { [weak self] records in
            guard let self else { return }
            // Apply the mode held *now*, not one captured when the query
            // started: the fetch is async, so a header click can land while
            // it is still running.
            self.records = Self.sort(records: records, mode: self.sortMode)
        }
    }

    /// Pure value-in / value-out sort, shared by `sortMode`'s didSet and the
    /// query callback.
    ///
    /// Name is the final tie-break everywhere, so equal byte counts keep a
    /// stable, readable order. `factor` sorts on the raw multiplier, in which
    /// 0 means "no 7-day median to compare against" (the record encodes ∞ that
    /// way) — those rows therefore land at the bottom instead of posing as the
    /// smallest increase.
    static func sort(records: [AlertRecord], mode: AlertSortMode) -> [AlertRecord] {
        func byName(_ l: AlertRecord, _ r: AlertRecord) -> Bool {
            l.name.localizedCaseInsensitiveCompare(r.name) == .orderedAscending
        }
        return records.sorted { l, r in
            switch mode {
            case .time:
                if l.date != r.date { return l.date > r.date }
                return byName(l, r)
            case .name:
                return byName(l, r)
            case .direction:
                // Downloads before uploads, each group newest first.
                if l.isIn != r.isIn { return l.isIn }
                if l.date != r.date { return l.date > r.date }
                return byName(l, r)
            case .today:
                if l.todayBytes != r.todayBytes { return l.todayBytes > r.todayBytes }
                return byName(l, r)
            case .median:
                if l.baselineBytes != r.baselineBytes { return l.baselineBytes > r.baselineBytes }
                return byName(l, r)
            case .factor:
                if l.multiplier != r.multiplier { return l.multiplier > r.multiplier }
                return byName(l, r)
            }
        }
    }

    /// Export the listed alerts as CSV — exactly the rows on screen, so the
    /// range filter applies. Unlike the other two tabs there is nothing to
    /// re-query: the log already is one row per event (the stats tab has to go
    /// back to the raw minute buckets because its table is an aggregate).
    func exportCSV() {
        CSVExporter.save(csv: CSVExporter.alertCSV(records), suggestedName: "alert-log.csv")
    }

    /// Epoch-ms lower bound for the selected range (0 = unbounded).
    static func fromMs(range: AlertRange, customFrom: Date, customTo: Date) -> Int64 {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let from: Date?
        switch range {
        case .all:
            from = nil
        case .today:
            from = today
        case .last7Days:
            from = calendar.date(byAdding: .day, value: -6, to: today)
        case .last30Days:
            from = calendar.date(byAdding: .day, value: -29, to: today)
        case .custom:
            from = calendar.startOfDay(for: min(customFrom, customTo))
        }
        return from.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }
}

struct AlertLogView: View {
    @StateObject private var model = AlertLogModel()
    @ObservedObject private var l10n = LocalizationManager.shared
    // The accent colour arrives through the environment (published by the
    // window root's appAccentScope), so the active sort header repaints with
    // it — same as the process-stats tab.
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: range filter + export
            HStack(spacing: 8) {
                Picker("", selection: $model.range) {
                    ForEach(AlertRange.allCases) { range in
                        Text(Loc.l(range.labelKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // No fixed width: a segmented control is bridged AppKit and
                // overdraws its neighbours rather than wrapping — see the note
                // in HistoryWindowView. This tab has five segments, the widest
                // filter row in the window.
                // Bridged AppKit controls keep stale titles after a language
                // change, so the segmented control is rebuilt per locale —
                // `.id` sits here rather than on the view root (as in the other
                // two tabs): on the root it would tear down `model` too, which
                // discarded the user's sort selection and re-queried the
                // database on every language change. The rest of this view's
                // strings are plain `Text`s built in `body`, and observing
                // `l10n` is enough to refresh those.
                .id(l10n.locale)

                // Export flush with the trailing edge — the same place every
                // other tab puts it, so the button does not move as tabs switch.
                Spacer()

                Button {
                    model.exportCSV()
                } label: {
                    Text(Loc.l("Export"))
                }
                .buttonStyle(.borderless)
                .help(Loc.l("Export CSV"))
            }

            // Row 2 (custom only): date bounds
            if model.range == .custom {
                HStack(spacing: 8) {
                    Text(Loc.l("From"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    // Hand-built date fields so the picked value follows the app
                    // accent (app-wide, see Feature/Appearance/AccentControls.swift).
                    AccentDateField(date: $model.customFrom, latest: Date())
                        .frame(width: 130)
                    Text(Loc.l("To"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    AccentDateField(date: $model.customTo, latest: Date())
                        .frame(width: 130)
                    Spacer()
                }
            }

            // Separate the filter block above from the log below — the same
            // divider (in the same place) the process-stats tab draws.
            Divider()

            // Column headers double as sort controls: clicking one sorts by
            // that column, and the active column is drawn in the accent colour
            // with a short underline. Same interaction as the process-stats tab
            // and the popover's process list.
            HStack(spacing: 8) {
                headerCell(Loc.l("Time"), 140, .leading, .time)
                headerCell(Loc.l("Name"), nil, .leading, .name)
                headerCell(Loc.l("Direction"), 44, .center, .direction)
                headerCell(Loc.l("Today"), 70, .trailing, .today)
                headerCell(Loc.l("Median (7d)"), 76, .trailing, .median)
                headerCell(Loc.l("Factor"), 58, .trailing, .factor)
            }

            if model.records.isEmpty {
                Spacer()
                Text(Loc.l("no alerts recorded"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.records.enumerated()), id: \.offset) { _, record in
                            alertRow(record)
                                .padding(.vertical, 3)
                        }
                    }
                }

                Divider()

                // Row count as a footer, the position the process-stats tab
                // uses for its grand total: it summarises the table, so it
                // belongs under it rather than between the filters and the
                // header. Only shown when there is a table to count.
                HStack {
                    Text(String(format: Loc.l("%ld alerts"), model.records.count))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            Text(Loc.l("Alert log note"))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.reload() }
    }

    /// One column header that is also a sort control: the width and alignment
    /// match the cells below so the header lines up with its column, and the
    /// column currently driving the sort is drawn in the accent colour with a
    /// short underline while the rest stay secondary.
    ///
    /// `width == nil` is the flexible name column, which takes the slack.
    private func headerCell(_ text: String, _ width: CGFloat?, _ alignment: Alignment,
                            _ mode: AlertSortMode) -> some View {
        let isActive = model.sortMode == mode
        return Text(text)
            .font(.system(size: 9, weight: isActive ? .semibold : .medium))
            .foregroundColor(isActive ? appAccent : .secondary)
            // Stay on one line inside the fixed column. Russian "Median (7d)"
            // measures 74 pt against a 76 pt column; wrapping would grow the
            // header row (and carry the sort underline with it) while shrinking
            // slightly does not.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .overlay(
                Rectangle()
                    .fill(isActive ? appAccent : Color.clear)
                    .frame(height: 2)
                    .offset(y: 3),
                alignment: .bottom
            )
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .contentShape(Rectangle())
            .onTapGesture { model.sortMode = mode }
    }

    private func alertRow(_ record: AlertRecord) -> some View {
        let appInfo = getAggregatedAppInfo(name: record.name)
        let factorText = record.baselineBytes > 0
            ? String(format: "%.1f×", record.multiplier)
            : "—"
        return HStack(spacing: 8) {
            Text(timeFormatter.string(from: record.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Image(nsImage: appInfo.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
            Text(appInfo.name ?? record.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.isIn ? "↓" : "↑")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(record.isIn ? .green : .orange)
                .frame(width: 44, alignment: .center)
            Text(formatBytesCompact(bytes: record.todayBytes))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
            Text(formatBytesCompact(bytes: record.baselineBytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(factorText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .help(record.name)
    }

    /// Localized, and rebuilt per row rather than cached in a `static let`:
    /// the language can be changed at runtime, and a cached formatter would
    /// keep the old one. The template carries the locale's own field order and
    /// 12/24-hour choice; the Time column is wide enough for the longest form
    /// (`9/20/2026, 2:30:00 PM`) that a locale-neutral pattern used to hide.
    private var timeFormatter: DateFormatter {
        Loc.dateFormatter(template: "yMdjms")
    }
}
