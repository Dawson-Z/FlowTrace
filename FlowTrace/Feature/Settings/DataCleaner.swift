//
//  DataCleaner.swift
//  FlowTrace — Feature/Settings
//
//  The in-memory half of the "Clear data" action: resets every live counter
//  so the user can start a clean measurement (e.g. compare one app's usage
//  after a reboot). The on-disk deletion lives in the Settings window, which
//  calls `HistoryPersistence.deleteRange` and then lands here.
//

import Foundation

enum DataCleaner {

    /// Reset the in-memory counters (no SQL). Called by the Settings window
    /// after it has removed the on-disk rows, so the live sparkline /
    /// summary / period totals / snapshots cannot outlive the rows they were
    /// derived from.
    static func resetInMemory() {
        SharedStore.historyStore.clearMemory()
        SharedStore.usageAggregator.reset()
        SharedStore.interfaceModel.reset()
        SharedStore.interfaceMinuteAggregator.reset()
        SharedStore.processAlertMonitor.reset()
        // Force the quota monitor to forget crossed thresholds so a cleared
        // baseline can notify again from scratch.
        SharedStore.quotaMonitor.resetFiredKeys()
    }
}
