//
//  HistoryWindowView.swift
//  FlowTrace — Feature/History
//
//  Content of the standalone history window. Three tabs:
//    - App usage (per-process accumulated bytes over a range)
//    - Heatmap (hour × day grid + interface-category filter)
//    - Alert log (per-day abnormal-traffic records)
//
//  Each tab keeps its own @StateObject model, so switching tabs and coming
//  back preserves filters. The hosting controller is cached by AppDelegate,
//  so the state also survives window close/reopen.
//

import SwiftUI

enum HistoryTab: String, CaseIterable, Identifiable {
    case appUsage
    case heatmap
    case alerts

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .appUsage: return "App usage"
        case .heatmap:  return "Network heatmap"
        case .alerts:   return "Alert log"
        }
    }
}

/// External handle for the window's selected tab — the same pattern as
/// `SettingsTabSelection`. AppDelegate keeps the instance alive so a
/// notification click can open the window directly on the alert log.
final class HistoryTabSelection: ObservableObject {
    @Published var tab: HistoryTab = .appUsage
}

struct HistoryWindowView: View {
    @ObservedObject var selection: HistoryTabSelection
    @ObservedObject private var l10n = LocalizationManager.shared
    // Observe so appearance/accent changes re-render this window live.
    @ObservedObject private var settings = SettingsStore.shared
    // Accent manager observed at the root so the window repaints instantly
    // on a colour/mode change (or a system-accent change in follow mode).
    @ObservedObject private var accent = AccentColorManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selection.tab) {
                ForEach(HistoryTab.allCases) { tab in
                    Text(Loc.l(tab.labelKey)).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            // Bridged AppKit controls keep stale segment titles after a
            // runtime language change; rebuilding per locale re-renders them.
            .id(l10n.locale)

            switch selection.tab {
            case .appUsage:
                AppUsageView()
            case .heatmap:
                HistoryHeatmapTabView()
            case .alerts:
                AlertLogView()
            }
        }
        .padding(14)
        // Top-align the content so the tab bar sits just under the title in
        // both tabs; a fixed height with the default .center alignment would
        // distribute the leftover blank space differently per tab height.
        // Height 560 leaves room for the extra date pickers in "custom".
        .frame(minWidth: 680, minHeight: 560, alignment: .top)
        // The one accent application point for this window: tints every
        // control and publishes `\.appAccent` to the whole subtree.
        .appAccentScope(accent.accent)
        .animation(.easeInOut(duration: 0.2), value: accent.animationIdentity)
    }
}

/// Extracted so each tab's @StateObject lives as long as the window, not as
/// long as the switch branch (a plain `if` would recreate models on toggle).
private struct HistoryHeatmapTabView: View {
    @StateObject private var model = HistoryHeatmapModel()
    @State private var direction: HeatmapDirection = .dayPerRow
    @State private var hovered: HeatmapCell?
    @ObservedObject private var l10n = LocalizationManager.shared
    // The accent colour arrives through the environment (published by the
    // window root's appAccentScope), so the legend repaints with it.
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: range presets + direction toggle
            HStack(spacing: 8) {
                Picker("", selection: $model.range) {
                    ForEach(HeatmapRange.allCases) { range in
                        Text(Loc.l(range.labelKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // No fixed width: a segmented control is a bridged AppKit view
                // and does not wrap or truncate like a SwiftUI `Text` — forcing
                // 300 pt made it overdraw its neighbours in most languages
                // (French needs 438 pt: "7 derniers jours", "Personnalisé").
                // Left to its intrinsic width, the `Spacer` below absorbs the
                // slack instead.
                .id(l10n.locale)

                Spacer()

                // Direction toggle, then export flush with the trailing edge —
                // the export button holds the rightmost slot in every tab that
                // has one, so it does not move as tabs switch. That means the
                // direction toggle sits to its left rather than at the edge.
                Picker("", selection: $direction) {
                    ForEach(HeatmapDirection.allCases) { dir in
                        Text(dir.symbol).tag(dir)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 76)
                .id(l10n.locale)
                .help(direction == .dayPerRow
                      ? Loc.l("Day as row")
                      : Loc.l("Day as column"))

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
                    AccentDateField(date: $model.customFrom)
                        .frame(width: 130)
                    Text(Loc.l("To"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    AccentDateField(date: $model.customTo, latest: Date())
                        .frame(width: 130)
                }
            }

            // Row 3: interface-category filter — each checkbox is one network
            // interface's usage; all on = total external traffic summed.
            HStack(spacing: 10) {
                Text(Loc.l("Interface"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                ForEach(InterfaceCategory.allCases) { category in
                    // Native switch with its own label — the category name.
                    // `minWidth`, not a fixed width: even English needs 116 pt
                    // for "Local Direct" + the switch, and Russian needs 162
                    // ("Локальное прямое"), so a hard 100 pt overlapped.
                    Toggle(Loc.l(category.rawValue), isOn: categoryBinding(category))
                        .toggleStyle(.switch)
                        .frame(minWidth: 100, alignment: .leading)
                }
                Spacer()
            }

            Divider()

            // Heatmap grid fills the remaining space above the fixed footer.
            HistoryHeatmapView(cells: model.cells,
                               direction: direction,
                               model: model,
                               hovered: $hovered)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 340)

            // The three footer lines (hover readout / colour legend / stats
            // note) stay as one fixed block pinned to the window bottom — the
            // same bottom padding as the App-usage note — independent of grid
            // height or direction, so nothing overlaps.
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(hovered.map { hoverText($0) } ?? " ")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(Loc.l("Less"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    ForEach([0.15, 0.35, 0.6, 0.85, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(appAccent.opacity(level))
                            .frame(width: 12, height: 12)
                    }
                    Text(Loc.l("More"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Text(Loc.l("Heatmap stats note"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Loc.l("Heatmap interface range"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Loc.l("Heatmap total gap note"))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.reload() }
    }

    /// Hover readout for a cell, in cumulative bytes (download / upload /
    /// total), rendered in the fixed footer.
    private func hoverText(_ cell: HeatmapCell) -> String {
        let down = cell.inBytes
        let up = cell.outBytes
        return "\(dayLabel(cell.day)) \(String(format: "%02d", cell.hour)):00  ↓\(formatBytesCompact(bytes: down))  ↑\(formatBytesCompact(bytes: up))  Σ\(formatBytesCompact(bytes: down + up))"
    }

    private func dayLabel(_ day: Int) -> String {
        Loc.dateFormatter(template: "Md").string(from: model.date(forDay: day))
    }

    /// Checkbox binding for one category: toggling mutates the model's set,
    /// whose didSet triggers reload. All-off is allowed and reads as an
    /// empty grid (deliberate: it never silently means "all").
    private func categoryBinding(_ category: InterfaceCategory) -> Binding<Bool> {
        Binding(
            get: { model.selectedCategories.contains(category) },
            set: { on in
                if on { model.selectedCategories.insert(category) }
                else { model.selectedCategories.remove(category) }
            }
        )
    }
}
