//
//  InterfaceModel.swift
//  iTrafficPlus — Feature/Interface
//
//  ObservableObject that holds the latest per-category interface
//  snapshot, so the popover's interface overview row can repaint on the
//  same cadence as the process list (every ~2 s nettop frame).
//

import Foundation

final class InterfaceModel: ObservableObject {
    @Published private(set) var snapshot: InterfaceSnapshot = .empty
    /// Top processes per interface type (milestone 10). Keyed by type so
    /// the view can look up one type's list without re-scanning.
    @Published private(set) var topSnapshots: [InterfaceTopType: InterfaceTopSnapshot] = [:]

    func update(_ new: InterfaceSnapshot) {
        // Only publish when something actually changed to avoid a redundant
        // view update on frames where the totals did not move.
        if new != snapshot {
            snapshot = new
        }
    }

    func updateTop(_ new: [InterfaceTopSnapshot]) {
        let dict = Dictionary(uniqueKeysWithValues: new.map { ($0.type, $0) })
        if dict != topSnapshots {
            topSnapshots = dict
        }
    }
}
