//
//  HistoryHeatmapView.swift
//  FlowTrace — Feature/History
//
//  The hour × day heatmap grid, rendered with plain SwiftUI rectangles
//  (no Charts framework — deployment target is 11.0).
//
//  Two directions from the same `cells`:
//    .dayPerRow   — one row per day, 24 hour columns (reads like a table),
//                   with a trailing per-day cumulative-total column ("Σ")
//    .dayPerColumn — one column per day, 24 hour rows (GitHub style,
//                   scrolls horizontally), with a per-day cumulative-total
//                   row at the bottom of each column
//
//  Intensity = (in + out) share of the busiest cell. Hovering a cell shows
//  its cumulative ↓/↑/Σ bytes in a status line below the grid, updated
//  immediately (the old `.help` tooltip had a slow system delay).
//

import SwiftUI

enum HeatmapDirection: String, CaseIterable, Identifiable {
    case dayPerRow
    case dayPerColumn

    var id: String { rawValue }

    var symbol: String { self == .dayPerRow ? "☰" : "▥" }
}

struct HistoryHeatmapView: View {
    let cells: [HeatmapCell]
    let direction: HeatmapDirection
    let model: HistoryHeatmapModel
    /// The cell currently under the pointer; bound to the owning tab so the
    /// hover readout can live in a fixed bottom block (moved out of the grid).
    @Binding var hovered: HeatmapCell?
    /// The accent arrives through the `\.appAccent` environment value
    /// (published by the window root), so a colour change re-renders the
    /// grid without this view knowing the manager.
    @Environment(\.appAccent) private var appAccent

    // Absolute day index -> localised label, computed once per update.
    private var cellByKey: [Int: HeatmapCell] {
        Dictionary(cells.map { ($0.day * 24 + $0.hour, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var days: [Int] {
        Array(Set(cells.map(\.day))).sorted()
    }

    var body: some View {
        Group {
            if direction == .dayPerRow {
                dayPerRow
            } else {
                dayPerColumn
            }
        }
    }

    // MARK: - Direction 1: row per day

    private var dayPerRow: some View {
        let byKey = cellByKey
        return ScrollView {
            VStack(spacing: 2) {
                // Hour ruler — label every 6th hour. The trailing "Σ" heads
                // the per-day cumulative-total column.
                HStack(spacing: 0) {
                    Text("").frame(width: 52, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 6 == 0 ? "\(h)" : "")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    Text("Σ")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                ForEach(days, id: \.self) { day in
                    HStack(spacing: 0) {
                        Text(dayLabel(day))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 52, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            cellView(byKey[day * 24 + hour])
                                .frame(height: 16)
                                .frame(maxWidth: .infinity)
                        }
                        Text(formatBytesCompact(bytes: dayTotal(day: day)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Direction 2: column per day (GitHub style)

    private var dayPerColumn: some View {
        let byKey = cellByKey
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 2) {
                // Hour ruler column — label every 6th hour.
                VStack(alignment: .leading, spacing: 1) {
                    Text("")
                        .font(.system(size: 8))
                        .frame(height: 14)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 6 == 0 ? "\(h)" : "")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 12, alignment: .trailing)
                    }
                }
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 1) {
                        Text(dayLabel(day))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(height: 14)
                        ForEach(0..<24, id: \.self) { hour in
                            cellView(byKey[day * 24 + hour])
                                .frame(width: 34, height: 12)
                        }
                        Text(formatBytesCompact(bytes: dayTotal(day: day)))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Cell

    @ViewBuilder
    private func cellView(_ cell: HeatmapCell?) -> some View {
        let level = cell.map { intensity($0) } ?? 0
        Rectangle()
            .fill(cell == nil
                  ? Color.primary.opacity(0.04)
                  : appAccent.opacity(0.15 + 0.85 * level))
            .cornerRadius(2)
            .onHover { inside in
                if inside {
                    hovered = cell
                } else if hovered == cell {
                    hovered = nil
                }
            }
    }

    // MARK: - Helpers

    /// 0…1 share of the busiest cell (in + out bytes combined).
    private func intensity(_ cell: HeatmapCell) -> Double {
        let peak = cells.map { $0.inBytes + $0.outBytes }.max() ?? 0
        guard peak > 0 else { return 0 }
        return min(1, Double(cell.inBytes + cell.outBytes) / Double(peak))
    }

    private func dayLabel(_ day: Int) -> String {
        Loc.dateFormatter(template: "Md").string(from: model.date(forDay: day))
    }

    /// A day's cumulative bytes: SUM of each hour cell's bytes. Cells already
    /// hold absolute byte totals (SUM(rate) × interval), so no ×3600 here.
    private func dayTotal(day: Int) -> Int {
        cells.filter { $0.day == day }
            .reduce(0) { $0 + $1.inBytes + $1.outBytes }
    }
}
