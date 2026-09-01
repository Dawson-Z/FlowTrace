//
//  Store.swift
//  iTrafficPlus
//
//  Created by f.zou on 2021/5/23.
//  Forked in 2026 as part of iTrafficPlus research milestone 1.
//

import SwiftUI

enum SharedStore {
    static let listViewModel = ListViewModel()
    static let statusDataModel = StatusDataModel()
    static let globalModel = GlobalModel()
    // Outlives ContentView, which is torn down entirely when the popover sleeps.
    // The upstream's `updateChecker` is intentionally absent here: this fork has
    // no release channel to check, and the upstream's "exactly one network
    // request, only when clicked" rule is hardened to "no network request
    // period" in this fork.
    static let historyStore = HistoryStore(capacity: 60)
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.listViewModel)
        .environmentObject(SharedStore.statusDataModel)
        .environmentObject(SharedStore.globalModel)
        .environmentObject(SharedStore.historyStore)
    }
}
