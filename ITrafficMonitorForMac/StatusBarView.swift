//
//  StatusBarView.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//
//  Column layout:
//    [ rate column (fixed 55 pt) ][ totals column (34 pt) ]
//
//  Rate column always occupies its width when any rate is shown, so ↙/↗
//  never shift; the totals column stacks D (today) over M (month) in perfect
//  vertical alignment, regardless of which segments are enabled.
//  AppDelegate derives the item width from the same settings.
//

import SwiftUI

private let rateColumnWidth: CGFloat = 55
private let totalsColumnWidth: CGFloat = 34

struct StatusBarView: View {
    @StateObject var statusDataModel = SharedStore.statusDataModel
    @StateObject private var usage = SharedStore.usageAggregator
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 4) {
            rateColumn
            if settings.showTodayInMenuBar || settings.showMonthInMenuBar {
                totalsColumn
            }
        }
        .padding(.horizontal, 3)
    }

    // MARK: - Rate column (fixed width)

    private var rateColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            rateRow(show: settings.showDownloadInStatusBar,
                    glyph: "↙",
                    bytesPerSec: statusDataModel.totalInBytesPerSec)
            rateRow(show: settings.showUploadInStatusBar,
                    glyph: "↗",
                    bytesPerSec: statusDataModel.totalOutBytesPerSec)
        }
        .frame(width: rateColumnWidth, alignment: .leading)
    }

    @ViewBuilder
    private func rateRow(show: Bool, glyph: String, bytesPerSec: Int) -> some View {
        HStack(spacing: 3) {
            if show {
                Text(glyph)
                    .font(.system(size: 9))
                Text(rateString(bytesPerSec))
                    .font(.system(size: 9))
                    .fontWeight(.medium)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .frame(height: 10, alignment: .leading)
    }

    // MARK: - Totals column

    @ViewBuilder
    private var totalsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.showTodayInMenuBar {
                totalSegment(prefix: "D", value: usage.today)
            }
            if settings.showMonthInMenuBar {
                totalSegment(prefix: "M", value: usage.month)
            }
        }
        .frame(width: totalsColumnWidth, alignment: .leading)
    }

    // MARK: - Pieces

    /// Compact per-second rate: `9.1M/s`; "—" when idle.
    private func rateString(_ bytesPerSec: Int) -> String {
        bytesPerSec > 0 ? formatBytesCompact(bytes: bytesPerSec) + "/s" : "—"
    }

    /// Compact total segment: `D1.2G` / `M8.3G` (in+out combined).
    private func totalSegment(prefix: String, value: UsageBytes) -> some View {
        HStack(spacing: 1) {
            Text(prefix)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(formatBytesCompact(bytes: value.total))
                .font(.system(size: 9))
                .fontWeight(.medium)
        }
        .frame(height: 10, alignment: .leading)
    }
}

struct StatusBarView_Previews: PreviewProvider {
    static var previews: some View {
        StatusBarView()
            .environment(\.sizeCategory, .small)
    }
}
