//
//  InterfaceModel.swift
//  FlowTrace — Feature/Interface
//
//  ObservableObject that holds the latest per-category interface
//  snapshot, so the popover's interface overview row can repaint on the
//  same cadence as the process list (every ~2 s nettop frame).
//

import Foundation

final class InterfaceModel: ObservableObject {
    @Published private(set) var snapshot: InterfaceSnapshot = .empty
    /// Today's cumulative bytes per `InterfaceCategory` (String rawValue key).
    /// This is a live sum: a snapshot base loaded from the already-persisted
    /// interface history at the day boundary, plus per-frame deltas, so the
    /// popover's "usage today" rows track live traffic yet count from midnight.
    @Published private(set) var todayUsage: [String: (in: Int, out: Int)] = [:]
    private var todayBase: [String: (in: Int, out: Int)] = [:]
    private var todaySession: [String: (in: Int, out: Int)] = [:]
    /// Local-day anchor for `todayBase`; changes at midnight.
    private var todayDayKey: Int = 0

    func update(_ new: InterfaceSnapshot) {
        // Only publish when something actually changed to avoid a redundant
        // view update on frames where the totals did not move.
        if new != snapshot {
            snapshot = new
        }
    }

    /// Called every interface frame: accumulate per-category deltas into
    /// today's cumulative (base loaded once per day from persisted history).
    /// Keeps the popover's "usage today" rows real-time.
    func trackTodayFrame(_ snapshot: InterfaceSnapshot) {
        let today = Calendar.current.startOfDay(for: Date())
        let dayKey = Int(today.timeIntervalSince1970 / 86400)
        if dayKey != todayDayKey {
            todayDayKey = dayKey
            todayBase = [:]
            todaySession = [:]
            loadTodayBase(day: today)
        }
        for (cat, inB) in snapshot.bytesIn {
            let k = cat.rawValue
            var s = todaySession[k] ?? (in: 0, out: 0)
            s.in += inB
            todaySession[k] = s
        }
        for (cat, outB) in snapshot.bytesOut {
            let k = cat.rawValue
            var s = todaySession[k] ?? (in: 0, out: 0)
            s.out += outB
            todaySession[k] = s
        }
        publishToday()
    }

    /// Snapshot of today's per-category bytes already persisted in
    /// `interface_history` since local midnight.
    private func loadTodayBase(day: Date) {
        guard let persistence = SharedStore.historyPersistence else { return }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let fromMs = Int64(day.timeIntervalSince1970 * 1000)
        let toMs = Int64(tomorrow.timeIntervalSince1970 * 1000)
        persistence.interfaceUsageBytes(fromMs: fromMs, toMs: toMs, interval: 1) { [weak self] rows in
            guard let self else { return }
            self.todayBase = rows
            self.publishToday()
        }
    }

    /// Recompose the published `todayUsage` as base + session.
    private func publishToday() {
        var merged = todayBase
        for (k, delta) in todaySession {
            let b = merged[k] ?? (in: 0, out: 0)
            merged[k] = (in: b.in + delta.in, out: b.out + delta.out)
        }
        todayUsage = merged
    }

    /// Reset to empty (Settings "Clear data"). The live snapshot + today
    /// totals repopulate on the next nettop frame.
    func reset() {
        snapshot = .empty
        todayUsage = [:]
        todayBase = [:]
        todaySession = [:]
    }
}
