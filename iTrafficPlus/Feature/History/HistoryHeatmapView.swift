//
//  HistoryHeatmapView.swift
//  iTrafficPlus — Feature/History
//
//  The hour × day heatmap grid, rendered with plain SwiftUI rectangles
//  (no Charts framework — deployment target is 11.0).
//
//  Two directions from the same `cells`:
//    .dayPerRow   — one row per day, 24 hour columns (reads like a table)
//    .dayPerColumn — one column per day, 24 hour rows (GitHub style,
//                    scrolls horizontally)
//
//  Intensity = (in + out) share of the busiest cell. Hovering a cell shows
//  its ↓/↑ rates in a fixed status line below the grid.
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

    // Absolute day index -> localised label, computed once per update.
    private var cellByKey: [Int: HeatmapCell] {
        Dictionary(cells.map { ($0.day * 24 + $0.hour, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var days: [Int] {
        Array(Set(cells.map(\.day))).sorted()
    }

    var body: some View {
        VStack(spacing: 6) {
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
                // Hour ruler — label every 6th hour.
                HStack(spacing: 0) {
                    Text("").frame(width: 52, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 6 == 0 ? "\(h)" : "")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
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
                                .frame(width: 12, height: 12)
                        }
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
                  : Color.accentColor.opacity(0.15 + 0.85 * level))
            .cornerRadius(2)
            .help(cell.map(hoverText) ?? "")
    }

    // MARK: - Helpers

    /// 0…1 share of the busiest cell (in + out combined).
    private func intensity(_ cell: HeatmapCell) -> Double {
        let peak = cells.map { $0.avgInBytesPerSec + $0.avgOutBytesPerSec }.max() ?? 0
        guard peak > 0 else { return 0 }
        return min(1, Double(cell.avgInBytesPerSec + cell.avgOutBytesPerSec) / Double(peak))
    }

    private func dayLabel(_ day: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: model.date(forDay: day))
    }

    /// Hover text: mean rates for the hour plus the hour's implied volume
    /// (mean rate × 3600 s) — the display-layer unit conversion, in one place.
    private func hoverText(_ cell: HeatmapCell) -> String {
        let down = formatBytesCompact(bytes: cell.avgInBytesPerSec)
        let up = formatBytesCompact(bytes: cell.avgOutBytesPerSec)
        let hourVolume = formatBytesCompact(bytes: (cell.avgInBytesPerSec + cell.avgOutBytesPerSec) * 3600)
        return "\(dayLabel(cell.day)) \(String(format: "%02d", cell.hour)):00  ↓\(down) ↑\(up)  ≈\(hourVolume)/h"
    }
}
