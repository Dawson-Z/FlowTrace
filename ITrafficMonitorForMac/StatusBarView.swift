//
//  StatusBarView.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//
//  Single-row horizontal layout so optional segments can coexist within the
//  ~24 pt menu-bar thickness: `↗2.1K ↙800K · D1.2G · M8.3G`. The rate pair
//  is the upstream behaviour (default on); the D (today) / M (month) total
//  segments come from the shared UsageAggregator.
//

import SwiftUI

struct StatusBarView: View {
    @StateObject var statusDataModel = SharedStore.statusDataModel
    @StateObject private var usage = SharedStore.usageAggregator
    // SettingsStore is observed so a toggle change in the Settings window
    // is reflected on the next redraw (which happens whenever the next
    // nettop frame arrives). We do not need to repaint faster than that —
    // the status bar rates update on the same cadence.
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            if settings.showUploadInStatusBar {
                Text("↗")
                    .font(.system(size: 9))
                Text(formatBytes(bytes: statusDataModel.totalOutBytesPerSec))
                    .font(.system(size: 9))
                    .fontWeight(.medium)
                    .frame(width: 40, alignment: .leading)
            }
            if settings.showDownloadInStatusBar {
                Text("↙")
                    .font(.system(size: 9))
                Text(formatBytes(bytes: statusDataModel.totalInBytesPerSec))
                    .font(.system(size: 9))
                    .fontWeight(.medium)
                    .frame(width: 40, alignment: .leading)
            }
            if settings.showTodayInMenuBar {
                segment(prefix: "D", value: usage.today)
            }
            if settings.showMonthInMenuBar {
                segment(prefix: "M", value: usage.month)
            }
        }
        .padding(.horizontal, 2)
    }

    /// Compact total segment: `D1.2G` / `M8.3G` (in+out combined).
    private func segment(prefix: String, value: UsageBytes) -> some View {
        HStack(spacing: 1) {
            Text(prefix)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(formatBytesCompact(bytes: value.total))
                .font(.system(size: 9))
                .fontWeight(.medium)
        }
    }
}

struct StatusBarView_Previews: PreviewProvider {
    static var previews: some View {
        StatusBarView()
            .environment(\.sizeCategory, .small)
    }
}
