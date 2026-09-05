//
//  AppUsageView.swift
//  iTrafficPlus — Feature/History
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Range + sort controls
            HStack(spacing: 8) {
                Picker("", selection: $model.range) {
                    ForEach(HeatmapRange.allCases) { range in
                        Text(Loc.l(range.labelKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                Picker("", selection: $model.sortMode) {
                    ForEach(ListSortMode.allCases) { mode in
                        Text(Loc.l(mode.label)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if model.range == .custom {
                HStack(spacing: 8) {
                    Text(Loc.l("From"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $model.customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 130)
                    Text(Loc.l("To"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    DatePicker("", selection: $model.customTo, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 130)
                }
            }

            // Column headers
            HStack(spacing: 8) {
                Text(Loc.l("Name"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("↓")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Text("↑")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Text(Loc.l("Total"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 76, alignment: .trailing)
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
        .onAppear { model.reload() }
    }

    private func usageRow(_ row: ProcessUsageSummary) -> some View {
        let appInfo = getAppInfo(pid: 0, name: row.name)
        return HStack(spacing: 8) {
            Image(nsImage: appInfo?.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
            Text(appInfo?.name ?? row.name)
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
