//
//  Store.swift
//  FlowTrace
//
//  Created by f.zou on 2021/5/23.
//  Forked in 2026 as part of FlowTrace research milestone 1.
//

import SwiftUI

enum SharedStore {
    static var listViewModel = ListViewModel()
    static var statusDataModel = StatusDataModel()
    static var globalModel = GlobalModel()
    // Outlives ContentView, which is torn down entirely when the popover sleeps.
    // The upstream's `updateChecker` is intentionally absent here: this fork has
    // no release channel to check, and the upstream's "exactly one network
    // request, only when clicked" rule is hardened to "no network request
    // period" in this fork.
    //
    // `historyStore` is `static var` (not `let`) so AppDelegate can swap in
    // a SQLite-backed instance during applicationDidFinishLaunching. The
    // popover is not shown until *after* launch returns, so the race that
    // would make a `let` necessary does not exist on macOS — the first
    // ContentView is created in response to a status-bar click, which
    // happens strictly later.
    static var historyStore = HistoryStore(capacity: 60)
    // Latest per-interface-category aggregate. Kept as its own singleton so
    // a second nettop (socket mode, in InterfaceMonitor) can publish into it
    // without coupling to the process-level data path (milestone 9).
    static var interfaceModel = InterfaceModel()

    /// Rolls per-frame interface snapshots into local-minute buckets for the
    /// history window's network heatmap (minute-cadence source, mirroring
    /// `ProcessUsageAggregator`).
    static let interfaceMinuteAggregator = InterfaceMinuteAggregator()

    /// The one SQLite handle, shared by `HistoryStore` (per-frame totals)
    /// and `Network` (per-category interface rows) so both write through
    /// the same serial queue / WAL connection. Set during launch by
    /// `attachHistoryPersistence`; nil = persistence failed, features
    /// degrade to memory-only.
    static private(set) var historyPersistence: HistoryPersistence?

    /// Period usage integrator (quota + menu-bar totals share this single
    /// source). Reads `process_usage` bytes; throttled internally.
    static let usageAggregator = UsageAggregator()

    /// Quota threshold watcher; observes usage only while
    /// `SettingsStore.quotaEnabled` is on.
    static let quotaMonitor = QuotaMonitor()

    /// Per-process daily traffic alert watcher; no-op unless
    /// `uploadAlertEnabled`.
    static let processAlertMonitor = ProcessAlertMonitor()

    /// Wire SQLite persistence into the singletons. Must be called from
    /// `applicationDidFinishLaunching` (or any point strictly before the
    /// popover is first shown). Replaces the in-memory store with one
    /// that also writes every frame to `~/Library/Application Support/
    /// FlowTrace/history.sqlite3`, and seeds its ring buffer from the
    /// most recent 60 rows on disk so the sparkline is not empty after
    /// a restart.
    static func attachHistoryPersistence(_ p: HistoryPersistence) {
        historyPersistence = p
        historyStore = HistoryStore(capacity: 60, persistence: p)
        historyStore.bootstrap()
    }
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.listViewModel)
        .environmentObject(SharedStore.statusDataModel)
        .environmentObject(SharedStore.globalModel)
        .environmentObject(SharedStore.historyStore)
        .environmentObject(SharedStore.interfaceModel)
    }
}
