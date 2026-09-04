//
//  ContentView.swift
//  iTrafficPlus
//
//  Created by f.zou on 2021/5/19.
//

import SwiftUI

struct ContentView: View {
    // `@StateObject` rather than `@ObservedObject` so SwiftUI doesn't
    // re-subscribe to the singleton on every view re-creation. The value
    // source is a singleton that lives for the lifetime of the app; this is
    // exactly what `@StateObject(wrappedValue:)` is for.
    @StateObject var viewModel = SharedStore.listViewModel
    @StateObject var historyStore = SharedStore.historyStore
    // SettingsStore is read here so the search filter can pass
    // `caseInsensitive` through. `SearchFilter` is a pure function; the
    // setting is the only thing that changes its behaviour, and we want the
    // change to apply on the next keystroke, not on the next app launch.
    @ObservedObject var settings = SettingsStore.shared

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
                // Settings cog. Unicode glyph (U+2699) instead of an SF Symbol
                // because a Symbol would need `.font()` at menu-bar sizes and
                // would still get resized out of proportion — see AGENTS.md
                // rule on SF Symbols.
                Text("⚙")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .contentShape(Rectangle())
                    .animation(.none)
                    .onTapGesture {
                        NSApp.sendAction(#selector(AppDelegate.showSettingsWindow), to: nil, from: nil)
                    }
                    .help("Settings")
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

            // Sort selector (milestone 3 experiment). Picker writes
            // `viewModel.sortMode`; `ListViewModel.updateData` picks it up on
            // the next nettop frame. To make the switch feel instant, we
            // also call `viewModel.sort` on selection — but the Picker binding
            // alone is enough since `updateData` runs every 2 s. Kept inside
            // its own divider line so it reads as "filter" semantically.
            HStack(spacing: 6) {
                Text("Sort")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Picker("", selection: $viewModel.sortMode) {
                    ForEach(ListSortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider()

            // Process list (ScrollView + LazyVStack for full layout control;
            // SwiftUI List adds platform-specific leading insets that hid icons.)
            ScrollView {
                VStack(spacing: 0) {
                    let visible = SearchFilter.filter(
                        items: viewModel.items,
                        searchText: viewModel.searchText,
                        caseInsensitive: settings.caseInsensitiveSearch
                    )
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

            // Interface overview (milestone 9). Lives above the history
            // sparkline so the popover reads top-to-bottom as: header /
            // filter / sort / list / interface / history.
            InterfaceSummaryView()

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
