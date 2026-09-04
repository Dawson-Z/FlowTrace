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

    func update(_ new: InterfaceSnapshot) {
        // Only publish when something actually changed to avoid a redundant
        // view update on frames where the totals did not move.
        if new != snapshot {
            snapshot = new
        }
    }
}
