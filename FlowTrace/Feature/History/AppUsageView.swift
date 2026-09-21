//
//  AppUsageView.swift
//  FlowTrace — Feature/History
//
//  "App usage" tab: every process's accumulated download/upload/total bytes
//  over the selected range, sorted per ListSortMode, with a grand-total
//  footer. Icon resolution reuses getAppInfo (best effort — pid is unknown
//  for aggregated history, so the name drives the lookup).
//

import SwiftUI

struct AppUsageView: View {
    @StateObject private var model = ProcessUsageModel()
    @ObservedObject private var l10n = LocalizationManager.shared
    // The accent colour arrives through the environment (published by the
    // window root's appAccentScope), so the active sort header repaints with
    // it — same as the popover's process list.
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Range + export controls
            HStack(spacing: 8) {
                Picker("", selection: $model.range) {
                    ForEach(HeatmapRange.allCases) { range in
                        Text(Loc.l(range.labelKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // No fixed width: a segmented control is bridged AppKit and
                // overdraws its neighbours rather than wrapping — see the note
                // in HistoryWindowView.
                .id(l10n.locale)

                // Export is flush with the trailing edge, in every tab that has
                // one — so the button sits at the same place whichever tab is
                // showing.
                Spacer()

                Button {
                    model.exportCSV()
                } label: {
                    Text(Loc.l("Export"))
                }
                .buttonStyle(.borderless)
                .help(Loc.l("Export CSV"))
            }

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

            // Separate the filter block above from the list below — the same
            // divider the heatmap tab draws between its own filters and the
            // grid. The column headers stay on the list's side of it, since
            // they belong to the table rather than to the filters.
            Divider()

            // Column headers double as sort controls, the same interaction as
            // the popover's process list: clicking a header sorts by that
            // column and the active column is drawn in the accent colour with
            // a short underline. The two glyph columns both mean "sort by
            // bytes", so the arrow shows which direction is being ordered.
            HStack(spacing: 8) {
                Text(Loc.l("Name"))
                    .font(.system(size: 9, weight: model.sortMode == .name ? .semibold : .medium))
                    .foregroundColor(model.sortMode == .name ? appAccent : .secondary)
                    .overlay(
                        Rectangle()
                            .fill(model.sortMode == .name ? appAccent : Color.clear)
                            .frame(height: 2)
                            .offset(y: 3),
                        alignment: .bottom
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.sortMode = .name }
                valHeader("↓", 70, .todayDownload)
                valHeader("↑", 70, .todayUpload)
                valHeader(Loc.l("Total"), 76, .todayTotal)
            }

            if model.rows.isEmpty {
                Spacer()
                Text(Loc.l("no usage recorded"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                // Rows
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rows, id: \.name) { row in
                            usageRow(row)
                                .padding(.vertical, 3)
                        }
                    }
                }

                Divider()

                // Grand total footer
                let totalIn = model.rows.map(\.inBytes).reduce(0, +)
                let totalOut = model.rows.map(\.outBytes).reduce(0, +)
                HStack(spacing: 8) {
                    Text(Loc.l("Total"))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(formatBytesCompact(bytes: totalIn))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 70, alignment: .trailing)
                    Text(formatBytesCompact(bytes: totalOut))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 70, alignment: .trailing)
                    Text(formatBytesCompact(bytes: totalIn + totalOut))
                        .font(.system(size: 11, design: .monospaced))
                        .fontWeight(.medium)
                        .frame(width: 76, alignment: .trailing)
                }
            }
        }
        // Statistics note: per-process, per-minute bucket.
        Text(Loc.l("App usage stats note"))
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.reload() }
    }

    /// A value-column header that is also a sort control: the width matches
    /// the cells below so the header lines up with the numbers, and the column
    /// currently driving the sort is drawn in the accent colour with a short
    /// underline while the rest stay secondary — the popover's process list
    /// behaves the same way (see `ContentView.valHeader`).
    ///
    /// The display string arrives already localised, because the two glyph
    /// columns ("↓" / "↑") are not translation keys.
    private func valHeader(_ text: String, _ width: CGFloat, _ mode: ListSortMode) -> some View {
        let isActive = model.sortMode == mode
        return Text(text)
            .font(.system(size: 9, weight: isActive ? .semibold : .regular, design: .monospaced))
            .foregroundColor(isActive ? appAccent : .secondary)
            // One line inside the fixed column, shrinking a little rather than
            // wrapping and growing the header row — see AlertLogView.headerCell.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .overlay(
                Rectangle()
                    .fill(isActive ? appAccent : Color.clear)
                    .frame(height: 2)
                    .offset(y: 3),
                alignment: .bottom
            )
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { model.sortMode = mode }
    }

    private func usageRow(_ row: ProcessUsageSummary) -> some View {
        // Name-keyed lookup: NEVER getAppInfo(pid: 0, …) — that funnels all
        // rows through one cache slot and shows the first-seen name on every
        // row. The display name is the raw process name; only the icon is
        // borrowed from a matching running app.
        let appInfo = getAggregatedAppInfo(name: row.name)
        return HStack(spacing: 8) {
            Image(nsImage: appInfo.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(appInfo.name ?? row.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(formatBytesCompact(bytes: row.inBytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(formatBytesCompact(bytes: row.outBytes))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(formatBytesCompact(bytes: row.inBytes + row.outBytes))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 76, alignment: .trailing)
        }
        .help(row.name)
    }
}
