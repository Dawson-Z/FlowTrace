//
//  DataCleaner.swift
//  iTrafficPlus — Feature/Settings
//
//  Orchestrates the "Clear data" action: wipes every on-disk history table
//  and resets all in-memory state, so the user can start a clean measurement
//  (e.g. compare one app's usage after a reboot).
//

import Foundation

enum DataCleaner {

    /// Erase all recorded usage history (totals, interface, process usage)
    /// and reset the live in-memory counters (sparkline, summary, period
    /// totals, interface snapshot). `completion` runs on the main queue.
    static func clearAll(completion: @escaping () -> Void) {
        guard let persistence = SharedStore.historyPersistence else {
            // No persistence attached: still reset in-memory state.
            resetInMemory()
            completion()
            return
        }
        persistence.clearAllTables {
            resetInMemory()
            completion()
        }
    }

    private static func resetInMemory() {
        SharedStore.historyStore.clearMemory()
        SharedStore.usageAggregator.reset()
        SharedStore.interfaceModel.reset()
        // Force the quota monitor to forget crossed thresholds so a cleared
        // baseline can notify again from scratch.
        SharedStore.quotaMonitor.resetFiredKeys()
    }
}
