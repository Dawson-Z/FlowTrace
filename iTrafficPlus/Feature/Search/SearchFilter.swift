//
//  SearchFilter.swift
//  iTrafficPlus — Feature/Search
//
//  Pure-function filter for the process list. Kept in its own file so it can be
//  unit-tested without spinning up a SwiftUI body.
//

import Foundation

enum SearchFilter {
    /// Returns the subset of `items` whose name or PID contains `searchText`
    /// (case-insensitive, ASCII-folded). An empty `searchText` returns the
    /// input unchanged so we don't pay a copy on every frame when the bar is
    /// empty.
    static func filter(items: [ProcessEntity], searchText: String) -> [ProcessEntity] {
        let needle = searchText
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            if item.name.lowercased().contains(needle) { return true }
            // PIDs are short, so comparing them as decimal is enough. Skip the
            // String conversion when the needle clearly isn't numeric.
            if let needleInt = Int(needle), needleInt == item.pid { return true }
            return false
        }
    }
}
