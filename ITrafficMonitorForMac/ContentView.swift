//
//  ContentView.swift
//  iTrafficPlus
//
//  Created by f.zou on 2021/5/19.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var historyStore = SharedStore.historyStore

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image("Itraffic-logo-text")
                    .resizable()
                    .frame(width: 89.39, height: 20)
                Spacer()
                // No version line / no sibling-app glyph in this fork: the
                // upstream had a clickable "v0.2.2" that doubled as the update
                // entry point, and a ✨ that linked to Bytetally. Both are
                // out of scope here — there is no release channel and no
                // upsell surface to render. The header just shows the logo
                // and the trailing GitHub / Quit links.
                MenuItem(id: "menu.github", text: "Upstream", action: {
                    NSWorkspace.shared.open(URL(string: "https://github.com/foamzou/ITraffic-monitor-for-mac")!)
                })
                MenuItem(id: "menu.quit", text: "Quit", action: AppDelegate.quit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Search bar (milestone 1 experiment). Sits between the header
            // and the process list, separated by its own divider so the
            // visual hierarchy stays "header / filter / list / history".
            ProcessSearchBar(viewModel: viewModel)

            Divider()

            // Process list (ScrollView + LazyVStack for full layout control;
            // SwiftUI List adds platform-specific leading insets that hid icons.)
            ScrollView {
                VStack(spacing: 0) {
                    let visible = SearchFilter.filter(items: viewModel.items, searchText: viewModel.searchText)
                    let maxTotal = visible
                        .map { $0.inBytesPerSec + $0.outBytesPerSec }
                        .max() ?? 0
                    ForEach(visible) { entity in
                        ProcessRow(processEntity: entity, maxTotal: maxTotal)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()

            // Sparkline (milestone 1 experiment). Lives at the bottom; the
            // popover grows vertically to make room (see AppDelegate).
            HistoryView(store: historyStore)
        }
        .frame(width: 340)
        .background(Color("ContentBGColor"))
    }
}

struct ProcessRow: View {
    var processEntity: ProcessEntity
    var maxTotal: Int

    var body: some View {
        let appInfo = getAppInfo(pid: processEntity.pid, name: processEntity.name)
        let inActive  = processEntity.inBytesPerSec  > 0
        let outActive = processEntity.outBytesPerSec > 0
        let anyActive = inActive || outActive

        let total = processEntity.inBytesPerSec + processEntity.outBytesPerSec
        let totalRatio = maxTotal > 0 ? CGFloat(total) / CGFloat(maxTotal) : 0

        HStack(spacing: 8) {
            Image(nsImage: appInfo?.icon ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            Text(appInfo?.name ?? processEntity.name)
                .font(.system(size: 12, weight: anyActive ? .semibold : .regular))
                .foregroundColor(anyActive ? .primary : Color.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Down: same size as up; color only when active
            HStack(spacing: 2) {
                Text("↓")
                    .font(.system(size: 10))
                    .foregroundColor(inActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.inBytesPerSec))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(inActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 44, alignment: .trailing)
            }

            // Up: symmetric — same dimensions, same color rules
            HStack(spacing: 2) {
                Text("↑")
                    .font(.system(size: 10))
                    .foregroundColor(outActive ? .secondary : Color.secondary.opacity(0.35))
                Text(formatBytesCompact(bytes: processEntity.outBytesPerSec))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(outActive ? .primary : Color.secondary.opacity(0.35))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .background(
            // Single neutral activity bar. Length = this row's total
            // (in + out) / page-max-total. Direction info stays in
            // the numbers. Color.primary auto-adapts to dark mode.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: proxy.size.width * totalRatio)
                    Spacer(minLength: 0)
                }
            }
        )
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
