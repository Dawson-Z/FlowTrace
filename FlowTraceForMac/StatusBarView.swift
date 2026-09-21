//
//  StatusBarView.swift
//  FlowTrace
//
//  Created by f.zou on 2021/5/23.
//
//  Column layout:
//    [ rate column (fixed 49 pt) ][ totals column (38 pt) ]
//
//  Rate column always occupies its width when any rate is shown, so ↙/↗
//  never shift; the totals column stacks D (today) over P (the quota period)
//  in perfect vertical alignment, regardless of which segments are enabled.
//  AppDelegate derives the item width from the same settings — including the
//  4 pt gap between the two columns, which it used to forget.
//
//  Both widths are measured, not guessed. 9 pt gives ↙/↗ 7.04 pt and the
//  widest rate string ("999M/s") 34.32 pt inside its fixed 38 pt field, so
//  the rate column needs 7.04 + 3 + 38 = 48.04. The totals column has to fit
//  the longest realistic segment — "D 999M" is 34.00 pt, "D 1024G" is
//  37.2 pt — so 38 pt, not the old 34 pt, which clipped everything past
//  "D 86M" into an ellipsis once the D/P letters went from 8 pt to 9 pt.
//
//  The P segment follows `SettingsStore.quotaPeriod` — day / week / month —
//  so the menu bar answers the same question the quota alerts do ("how much
//  of this period have I used"), instead of always being the calendar month.
//  The period is read through `UsageAggregator.bytes(forPeriod:)`, the same
//  mapping `QuotaMonitor` uses, so the two can never disagree.
//

import SwiftUI

private let rateColumnWidth: CGFloat = 49
private let totalsColumnWidth: CGFloat = 38

struct StatusBarView: View {
    @StateObject var statusDataModel = SharedStore.statusDataModel
    @StateObject private var usage = SharedStore.usageAggregator
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 4) {
            rateColumn
            if settings.showTodayInMenuBar || settings.showPeriodInMenuBar {
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
            if settings.showPeriodInMenuBar {
                totalSegment(prefix: "P", value: usage.bytes(forPeriod: settings.quotaPeriod))
            }
        }
        .frame(width: totalsColumnWidth, alignment: .leading)
    }

    // MARK: - Pieces

    /// Compact per-second rate: `9.1M/s`; "—" when idle.
    private func rateString(_ bytesPerSec: Int) -> String {
        bytesPerSec > 0 ? formatBytesCompact(bytes: bytesPerSec) + "/s" : "—"
    }

    /// Compact total segment: `D1.2G` / `P3.4G` (in+out combined).
    ///
    /// The letter is drawn in the same colour and size as the other glyphs in
    /// the bar (the ↙/↗ arrows, 9 pt in the label colour), leaving the value
    /// `.medium` so the number still leads. It used to be an 8 pt `.secondary`
    /// letter, which in the menu bar resolves to a dimmed grey over a
    /// translucent background — next to the bright number it read as faded,
    /// and it was the least legible thing in the item. Weight, not colour,
    /// carries the hierarchy now.
    private func totalSegment(prefix: String, value: UsageBytes) -> some View {
        HStack(spacing: 1) {
            Text(prefix)
                .font(.system(size: 9))
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
