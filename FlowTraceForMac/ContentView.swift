//
//  ContentView.swift
//  FlowTrace
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
    // Observing LocalizationManager repaints the whole popover when the
    // user changes the language override, so every Loc.l(...) re-reads.
    @ObservedObject private var l10n = LocalizationManager.shared
    // Accent colour is owned by the manager in Feature/Appearance;
    // observing it here means the popover repaints instantly when the
    // user changes it from the Settings window (or when the macOS system
    // accent changes while in "Follow system" mode).
    @ObservedObject private var accent = AccentColorManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // The fork's own mark and name, instead of the upstream
                // "iTraffic" wordmark image: the app icon (a bitmap, so
                // `.resizable()` is correct here — the AGENTS.md rule against
                // it is about SF Symbols) plus the app's name in the language
                // chosen in Settings, which is what the Finder and the menu
                // bar call the app.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                Text(Loc.appDisplayName)
                    .font(.headline)
                Spacer()
                // The fork drops the upstream's "Upstream" link: a monitor
                // should not advertise another product from its own header,
                // and the repo lives with the user, not a click away.
                // Settings and Quit are the only header controls — each an
                // icon + label pair via MenuItem's optional SF Symbol.
                MenuItem(id: "menu.settings", icon: "gearshape", text: Loc.l("Settings"), action: {
                    NSApp.sendAction(#selector(AppDelegate.showSettingsWindow), to: nil, from: nil)
                })
                .help(Loc.l("Settings"))
                MenuItem(id: "menu.quit", icon: "power", text: Loc.l("Quit"), action: AppDelegate.quit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Search bar (milestone 1 experiment). Sits between the header
            // and the process list, separated by its own divider so the
            // visual hierarchy stays "header / filter / list / history".
            ProcessSearchBar(viewModel: viewModel)

            Divider()

            // Column headers double as sort controls: clicking a header sorts
            // the list by that column. The active column is highlighted.
            HStack(spacing: 8) {
                Spacer().frame(width: 26)   // icon column placeholder
                Text(Loc.l("Name"))
                    .font(.system(size: 10, weight: viewModel.sortMode == .name ? .semibold : .regular))
                    .foregroundColor(viewModel.sortMode == .name ? accent.accent : .secondary)
                    .overlay(
                        Rectangle()
                            .fill(viewModel.sortMode == .name ? accent.accent : Color.clear)
                            .frame(height: 2)
                            .offset(y: 3),
                        alignment: .bottom
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.sortMode = .name }
                valHeader("Live download", 70, .downloadRate)
                valHeader("Live upload", 66, .uploadRate)
                valHeader("Down today", 64, .todayDownload)
                valHeader("Up today", 60, .todayUpload)
                valHeader("Total today", 64, .todayTotal)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            // Rebuild the header row on a locale change so the localised
            // column labels refresh (the old sort picker used to carry this
            // `.id`; removing it dropped the LocalizationManager subscription).
            .id(l10n.locale)

            // Process list (ScrollView + LazyVStack for full layout control;
            // SwiftUI List adds platform-specific leading insets that hid icons.)
            ScrollView {
                VStack(spacing: 0) {
                    let visible = SearchFilter.filter(
                        items: viewModel.items,
                        searchText: viewModel.searchText
                    )
                    let maxTotal = visible
                        .map { $0.inBytesPerSec + $0.outBytesPerSec }
                        .max() ?? 0
                    ForEach(visible) { entity in
                        ProcessRow(
                            processEntity: entity,
                            todayUsage: viewModel.todayUsage[entity.name.lowercased()],
                            maxTotal: maxTotal
                        )
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
        .frame(width: 540)
        .background(Color("ContentBGColor"))
        // The one accent application point for the popover: tints every
        // control and publishes `\.appAccent` to the whole subtree.
        .appAccentScope(accent.accent)
        // One fade for mode flips and colour changes alike.
        .animation(.easeInOut(duration: 0.2), value: accent.animationIdentity)
    }

    /// A labelled column header that is also a sort control. The label is
    /// localised; the width matches the value cells below so the header lines
    /// up with the numbers. The column currently driving the sort is shown in
    /// the accent colour with a short underline so the active sort is
    /// unmistakable; the rest are secondary.
    private func valHeader(_ key: String, _ width: CGFloat, _ mode: ListSortMode) -> some View {
        let isActive = viewModel.sortMode == mode
        return Text(Loc.l(key))
            .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            .foregroundColor(isActive ? accent.accent : .secondary)
            .overlay(
                Rectangle()
                    .fill(isActive ? accent.accent : Color.clear)
                    .frame(height: 2)
                    .offset(y: 3),
                alignment: .bottom
            )
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.sortMode = mode }
    }
}

struct ProcessRow: View {
    var processEntity: ProcessEntity
    /// Today's cumulative bytes for this process (lowercased-name key), if
    /// the minute-bucket source has it yet. `nil` = unknown, rendered as "—".
    var todayUsage: (inBytes: Int, outBytes: Int)?
    var maxTotal: Int

    var body: some View {
        let appInfo = getAppInfo(pid: processEntity.pid, name: processEntity.name)
        let inActive  = processEntity.inBytesPerSec  > 0
        let outActive = processEntity.outBytesPerSec > 0
        let anyActive = inActive || outActive

        let todayIn  = todayUsage?.inBytes ?? 0
        let todayOut = todayUsage?.outBytes ?? 0

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

            // Live rates (bytes/sec), then today's cumulative bytes. The
            // column headers label each; no per-cell symbol or /s suffix.
            valueCell(processEntity.inBytesPerSec, 70, active: inActive)
            valueCell(processEntity.outBytesPerSec, 66, active: outActive)
            valueCell(todayIn, 64, active: false)
            valueCell(todayOut, 60, active: false)
            valueCell(todayIn + todayOut, 64, active: false)
        }
        .contentShape(Rectangle())
        .background(
            // Single neutral activity bar. Length = this row's live total
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

    /// A numeric value cell. `active` rows (a live rate above zero) read in
    /// primary text; cumulative cells are always muted. The column header
    /// carries the unit, so the value is a bare compact byte count.
    private func valueCell(_ bytes: Int, _ width: CGFloat, active: Bool) -> some View {
        Text(formatBytesCompact(bytes: bytes))
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(active ? .primary : Color.secondary.opacity(0.5))
            .frame(width: width, alignment: .trailing)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
