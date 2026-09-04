//
//  SearchFilter.swift
//  iTrafficPlus — Feature/Search
//
//  Pure-function filter for the process list. Kept in its own file so it can be
//  unit-tested without spinning up a SwiftUI body.
//

import Foundation

enum SearchFilter {
    /// Returns the subset of `items` whose name or PID contains `searchText`.
    ///
    /// - parameter caseInsensitive: When true, name comparison is `lowercased()`
    ///   contains — the iTrafficPlus default (matches the comparator in
    ///   `ListViewModel.sort`, which uses `localizedCaseInsensitiveCompare`).
    ///   When false, comparison is exact and the user must type the
    ///   process name byte-for-byte. The setting is on `SettingsStore`.
    ///
    /// An empty `searchText` returns the input unchanged so we don't pay a
    /// copy on every frame when the bar is empty.
    static func filter(
        items: [ProcessEntity],
        searchText: String,
        caseInsensitive: Bool = true
    ) -> [ProcessEntity] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        // Build the comparison predicates once, outside the per-item closure,
        // so the inner loop is a flat contains() call rather than re-creating
        // the closure on every iteration. For ~100 rows this is microseconds,
        // but the pattern is the same in either regime.
        let needle = caseInsensitive ? trimmed.lowercased() : trimmed
        let namePredicate: (String) -> Bool = { name in
            caseInsensitive ? name.lowercased().contains(needle) : name.contains(needle)
        }
        return items.filter { item in
            if namePredicate(item.name) { return true }
            if let needleInt = Int(needle), needleInt == item.pid { return true }
            return false
        }
    }
}
