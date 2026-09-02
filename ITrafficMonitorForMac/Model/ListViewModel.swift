//
//  ListViewModel.swift
//  iTrafficPlus
//
//  Created by f.zou on 2021/5/23.
//

import Foundation

/// How `ListViewModel.sort(items:)` orders the rows the user sees.
///
/// Kept in this file (rather than as a top-level enum) so any change to the
/// order is right next to the comparator that implements it. Adding a new
/// mode means: ① a new case, ② a new Picker option in `ContentView`,
/// ③ a new branch in `sort(items:)` — all three sit within ~30 lines.
enum ListSortMode: String, CaseIterable, Identifiable {
    case total      // in + out, descending — the default
    case download   // in  only, descending
    case upload     // out only, descending
    case name       // A-Z, case-insensitive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .total:    return "Total"
        case .download: return "Down"
        case .upload:   return "Up"
        case .name:     return "Name"
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
    @Published var sortMode: ListSortMode = .total
    var globalModel = SharedStore.globalModel
    var gcCounter = 0

    public func updateData(newItems: [ProcessEntity]) {
        if shouldClearItemsForReduceSomeMemory() {
            items.removeAll()
        }

        var pid2IndexForItems = [Int: Int]()
        var pidInNewItems = [Int: Int]()
        for (i, item) in items.enumerated() {
            pid2IndexForItems[item.pid] = i
        }

        for newItem in newItems {
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

    /// Stable on total-rate first; within ties, name is the secondary key.
    /// For the `.name` mode the comparator returns `lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending`
    /// so a re-sort under the same data is identical to a no-op.
    func sort(items: [ProcessEntity]) -> [ProcessEntity] {
        let mode = sortMode
        return items.sorted { (lhs, rhs) in
            switch mode {
            case .total:
                let lTotal = lhs.inBytesPerSec + lhs.outBytesPerSec
                let rTotal = rhs.inBytesPerSec + rhs.outBytesPerSec
                if lTotal != rTotal { return lTotal > rTotal }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .download:
                if lhs.inBytesPerSec != rhs.inBytesPerSec { return lhs.inBytesPerSec > rhs.inBytesPerSec }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .upload:
                if lhs.outBytesPerSec != rhs.outBytesPerSec { return lhs.outBytesPerSec > rhs.outBytesPerSec }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .name:
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
