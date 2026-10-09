//
//  ListViewModel.swift
//  FlowTrace
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import Combine

/// How `ListViewModel.sort(items:)` orders the rows the user sees.
///
/// Case order = display order in the popover's sort Picker, deliberately
/// matching the column order of the process list (Name / Down / Up / Total)
/// so the sort options read left-to-right like the table itself.
/// Kept in this file (rather than as a top-level enum) so any change to the
/// order is right next to the comparator that implements it. Adding a new
/// mode means: ① a new case, ② a new Picker option in `ContentView`,
/// ③ a new branch in `sort(items:mode:)` — all three sit within ~30 lines.
enum ListSortMode: String, CaseIterable, Identifiable {
    case name          = "name"                 // A-Z, case-insensitive
    case downloadRate  = "download"             // live download rate, descending
    case uploadRate    = "upload"               // live upload rate, descending
    case todayDownload = "cumulativeDownload"   // today's cumulative in bytes, descending
    case todayUpload   = "cumulativeUpload"     // today's cumulative out bytes, descending
    case todayTotal    = "cumulativeTotal"      // today's cumulative in + out, descending — default

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name:          return "Name"
        case .downloadRate:  return "Live ↓"
        case .uploadRate:    return "Live ↑"
        case .todayDownload: return "Today ↓"
        case .todayUpload:   return "Today ↑"
        case .todayTotal:    return "Today ∑"
        }
    }
}

class ListViewModel: ObservableObject {

    @Published var items: [ProcessEntity] = []
    /// Mirrors the user's text in the search bar. Set by `ProcessSearchBar`;
    /// read by `ContentView` to filter the rendered list. Never consumed by
    /// `updateData` — keeping the merge and the filter in different layers
    /// means a keystroke does not invalidate the cached PID-merge work.
    @Published var searchText: String = ""
    /// Sort order. The Picker in `ContentView` writes here; `sort(items:)`
    /// reads it. Switches do not trigger a re-merge of the underlying
    /// `items` array — only the rendered order changes.
    ///
    /// Initial value comes from `SettingsStore.shared.defaultSortModeRaw`,
    /// which reads its own initial value from UserDefaults at SettingsStore
    /// init. We re-read it here so changes the user makes in the Settings
    /// window *after* this VM is constructed are *not* applied mid-session
    /// — the sort mode is a session-scoped preference, like "default sort"
    /// in a music player: it takes effect on next launch.
    @Published var sortMode: ListSortMode = {
        if let raw = SettingsStore.shared.defaultSortModeRaw as String?,
           let mode = ListSortMode(rawValue: raw) {
            return mode
        }
        return .downloadRate
    }()
    /// Today's cumulative bytes per display name (lowercased key), from the
    /// `process_usage` minute-buckets. Backs the popover's "today" columns
    /// and the cumulative sort modes. Refreshed on a throttle (see
    /// `refreshTodayUsageIfNeeded`).
    @Published var todayUsage: [String: (inBytes: Int, outBytes: Int)] = [:]
    /// Today's cumulative figures are a live sum: a snapshot base loaded from
    /// `process_usage` at the day boundary, plus per-frame deltas accumulated
    /// since launch. Keeps the popover's "today" columns real-time while still
    /// counting from local midnight (the base survives restarts).
    private var todayBase: [String: (inBytes: Int, outBytes: Int)] = [:]
    private var todaySession: [String: (inBytes: Int, outBytes: Int)] = [:]
    /// Local-day anchor for `todayBase`; changes at midnight.
    private var todayDayKey: Int = 0
    var globalModel = SharedStore.globalModel
    var gcCounter = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Re-sort the visible rows immediately when the user switches the
        // sort mode. The sink MUST use the mode carried by the event:
        // @Published emits *before* the property is written, so re-reading
        // `self.sortMode` here would sort with the previous mode (the
        // "takes effect one click late" bug).
        $sortMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newMode in
                guard let self else { return }
                self.items = self.sort(items: self.items, mode: newMode)
            }
            .store(in: &cancellables)
    }

    public func updateData(newItems: [ProcessEntity]) {
        if shouldClearItemsForReduceSomeMemory() {
            items.removeAll()
        }

        // Milestone 11: collapse the frame's processes that share a name
        // into one row. nettop reports each PID separately (e.g. Electron
        // helper processes, "Trae CN Helper.86108/.86111/.86112"), so a
        // single app can appear as several rows. Summing the rates under the
        // shared display name gives a cleaner, more accurate "this app" view.
        let mergedItems = ListViewModel.mergeSameNameProcesses(newItems)

        var pid2IndexForItems = [Int: Int]()
        var pidInNewItems = [Int: Int]()
        for (i, item) in items.enumerated() {
            pid2IndexForItems[item.pid] = i
        }

        for newItem in mergedItems {
            let i = pid2IndexForItems[newItem.pid] ?? -1
            if i != -1 {
                items[i].icon = newItem.icon
                items[i].name = newItem.name
                items[i].inBytesPerSec = newItem.inBytesPerSec
                items[i].outBytesPerSec = newItem.outBytesPerSec
            } else {
                items.append(newItem)
                pid2IndexForItems[newItem.pid] = items.count - 1
            }
            pidInNewItems[newItem.pid] = 1
        }

        items = items.filter { pidInNewItems[$0.pid] != nil }
        items = sort(items: items)
    }

    /// Accumulate one frame of per-process deltas into today's cumulative and
    /// republish. Called every nettop frame on the main queue, so the popover's
    /// "today" columns track live traffic (see `loadTodayBase` for the base).
    func trackTodayUsage(entities: [ProcessEntity], interval: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayKey = Int(today.timeIntervalSince1970 / 86400)
        if dayKey != todayDayKey {
            todayDayKey = dayKey
            todaySession = [:]
            todayBase = [:]
            loadTodayBase(day: today)
        }
        let step = max(1, interval)
        for e in entities {
            let key = e.name.lowercased()
            var s = todaySession[key] ?? (inBytes: 0, outBytes: 0)
            s.inBytes += e.inBytesPerSec * step
            s.outBytes += e.outBytesPerSec * step
            todaySession[key] = s
        }
        publishToday()
    }

    /// Snapshot of today's cumulative bytes already persisted in `process_usage`
    /// (minute buckets) since local midnight. The live frame deltas on top keep
    /// the popover real-time without losing the "today" day boundary.
    private func loadTodayBase(day: Date) {
        guard let persistence = SharedStore.historyPersistence else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: day)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        // Same local-ordinal convention as ProcessUsageAggregator.bucket.
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        let fromBucket = Int((today.timeIntervalSince1970 + tz) / 60)
        let toBucket = Int((tomorrow.timeIntervalSince1970 + tz) / 60)
        persistence.processUsage(fromBucket: fromBucket, toBucket: toBucket) { [weak self] rows in
            guard let self else { return }
            var map: [String: (inBytes: Int, outBytes: Int)] = [:]
            for r in rows { map[r.name.lowercased()] = (r.inBytes, r.outBytes) }
            self.todayBase = map
            self.publishToday()
        }
    }

    /// Recompose the published `todayUsage` as base + session, and re-sort if
    /// the current mode is cumulative.
    private func publishToday() {
        var merged = todayBase
        for (key, delta) in todaySession {
            let b = merged[key] ?? (inBytes: 0, outBytes: 0)
            merged[key] = (inBytes: b.inBytes + delta.inBytes, outBytes: b.outBytes + delta.outBytes)
        }
        todayUsage = merged
        switch sortMode {
        case .todayDownload, .todayUpload, .todayTotal:
            items = sort(items: items, mode: sortMode)
        default:
            break
        }
    }

    /// Collapse processes sharing a case-insensitive display name into a
    /// single entity: rates sum, pid keeps the smallest (so the row stays
    /// stable frame-to-frame), name keeps the first-seen spelling. Pure
    /// function, unit-testable.
    static func mergeSameNameProcesses(_ entities: [ProcessEntity]) -> [ProcessEntity] {
        var byName: [String: ProcessEntity] = [:]
        var order: [String] = []
        for e in entities {
            let key = e.name.lowercased()
            if var existing = byName[key] {
                existing.inBytesPerSec += e.inBytesPerSec
                existing.outBytesPerSec += e.outBytesPerSec
                existing.pid = min(existing.pid, e.pid)
                byName[key] = existing
            } else {
                // Fresh entry inherits the first icon seen; subsequent frames
                // refresh it via the PID-merge path below.
                order.append(key)
                byName[key] = e
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// Stable on total-rate first; within ties, name is the secondary key.
    /// For the `.name` mode the comparator returns `lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending`
    /// so a re-sort under the same data is identical to a no-op.
    func sort(items: [ProcessEntity]) -> [ProcessEntity] {
        sort(items: items, mode: sortMode)
    }

    /// Pure value-in / value-out variant taking the mode explicitly — used by
    /// the `$sortMode` sink, which must sort with the *event's* mode rather
    /// than the (not-yet-written) property. See the init comment.
    func sort(items: [ProcessEntity], mode: ListSortMode) -> [ProcessEntity] {
        items.sorted { (lhs, rhs) in
            switch mode {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .downloadRate:
                if lhs.inBytesPerSec != rhs.inBytesPerSec { return lhs.inBytesPerSec > rhs.inBytesPerSec }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .uploadRate:
                if lhs.outBytesPerSec != rhs.outBytesPerSec { return lhs.outBytesPerSec > rhs.outBytesPerSec }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .todayDownload:
                let l = todayUsage[lhs.name.lowercased()]?.inBytes ?? 0
                let r = todayUsage[rhs.name.lowercased()]?.inBytes ?? 0
                if l != r { return l > r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .todayUpload:
                let l = todayUsage[lhs.name.lowercased()]?.outBytes ?? 0
                let r = todayUsage[rhs.name.lowercased()]?.outBytes ?? 0
                if l != r { return l > r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .todayTotal:
                let lu = todayUsage[lhs.name.lowercased()]
                let ru = todayUsage[rhs.name.lowercased()]
                let l = (lu?.inBytes ?? 0) + (lu?.outBytes ?? 0)
                let r = (ru?.inBytes ?? 0) + (ru?.outBytes ?? 0)
                if l != r { return l > r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    public func shouldClearItemsForReduceSomeMemory() -> Bool {
        gcCounter += 1
        if !self.globalModel.viewShowing && gcCounter >= 50 {
            gcCounter = 0
            return true
        }
        return false
    }
}
