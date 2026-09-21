//
//  SearchFilter.swift
//  FlowTrace — Feature/Search
//
//  Pure-function filter for the process list. Kept in its own file so it can be
//  unit-tested without spinning up a SwiftUI body.
//

import Foundation

enum SearchFilter {
    /// Returns the subset of `items` whose name or PID contains `searchText`.
    ///
    /// Name comparison is always case-insensitive (`lowercased()` contains —
    /// matches the comparator in `ListViewModel.sort`, which uses
    /// `localizedCaseInsensitiveCompare`). The old "case-insensitive search"
    /// setting is gone: the system behaviour is case-insensitive, so there
    /// is nothing to configure.
    ///
    /// An empty `searchText` returns the input unchanged so we don't pay a
    /// copy on every frame when the bar is empty.
    static func filter(
        items: [ProcessEntity],
        searchText: String
    ) -> [ProcessEntity] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        // Build the comparison predicate once, outside the per-item closure,
        // so the inner loop is a flat contains() call rather than re-creating
        // the closure on every iteration. For ~100 rows this is microseconds,
        // but the pattern is the same in either regime.
        let needle = trimmed.lowercased()
        let namePredicate: (String) -> Bool = { name in
            name.lowercased().contains(needle)
        }
        return items.filter { item in
            if namePredicate(item.name) { return true }
            if let needleInt = Int(needle), needleInt == item.pid { return true }
            return false
        }
    }
}
