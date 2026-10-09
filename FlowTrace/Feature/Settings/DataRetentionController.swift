//
//  DataRetentionController.swift
//  FlowTrace — Feature/Settings
//
//  Runs the daily retention checkpoint once per local day at the user's
//  configured time-of-day. Depending on the chosen cleanup mode it either:
//    - "automatic": deletes every row older than the retention window and
//      logs the operation (time, rows removed), or
//    - "manualNotification": if any expired rows exist, posts a reminder
//      notification containing the overdue row count and invites the user to
//      clear them / raise the retention window. The reminder repeats daily
//      until the user clears the data or raises retention so nothing is
//      overdue.
//
//  The row count is computed at fire-time (not baked into a static
//  notification), so the reminder always shows a live, accurate figure.
//
//  Scheduling model
//  ----------------
//  A 60 s Timer checks whether the configured time-of-day has passed today
//  and whether today's checkpoint has already run. This is robust against
//  sleep/wake and clock changes (the next tick re-evaluates), and needs no
//  re-arm logic when the user edits the time or retention days.
//

import Foundation
import AppKit
import Combine
import UserNotifications

final class DataRetentionController {

    static let shared = DataRetentionController()

    private let settings: SettingsStore
    private var timer: Timer?
    /// Day key ("yyyy-MM-dd") of the last checkpoint that fired, so we never
    /// fire twice for the same day even across wake cycles / restarts.
    private var lastFiredDay: String?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        // Editing any checkpoint input re-arms the day. Without this, a change
        // made *after* today's checkpoint had already run — e.g. lowering the
        // retention days from 360 to 2 while 1M rows are suddenly overdue —
        // stayed silent until tomorrow: the 16:28 tick had consumed the day on
        // a zero-overdue no-op, and nothing re-evaluated it (measured
        // 2026-09-23). Re-arming resets the marker and re-checks immediately;
        // the marker itself self-throttles, so a burst of edits fires at most
        // one checkpoint.
        settings.$cleanupModeRaw.dropFirst().sink { [weak self] _ in self?.rearm() }.store(in: &cancellables)
        settings.$historyRetentionDays.dropFirst().sink { [weak self] _ in self?.rearm() }.store(in: &cancellables)
        settings.$retentionTimeOfDay.dropFirst().sink { [weak self] _ in self?.rearm() }.store(in: &cancellables)
    }

    /// Begin the daily checkpoint loop. Idempotent (safe to call at launch).
    func start() {
        guard timer == nil else {
            tick()  // already running: still re-evaluate now (e.g. settings changed)
            return
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// Forget today's consumed marker and re-evaluate right away.
    private func rearm() {
        lastFiredDay = nil
        tick()
    }

    // MARK: - Checkpoint

    private func tick() {
        guard let persistence = SharedStore.historyPersistence else { return }

        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let target = today.addingTimeInterval(TimeInterval(settings.retentionTimeOfDay))

        // Not yet the configured time today → wait for the next tick.
        guard now >= target else { return }
        // Already handled today → do nothing (until tomorrow).
        let dayKey = Self.dayKey(now)
        guard lastFiredDay != dayKey else { return }
        lastFiredDay = dayKey

        let retentionDays = max(1, settings.historyRetentionDays)
        let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
        let cutoffMs = Int64(now.timeIntervalSince1970 * 1000) - Int64(retentionDays) * 86400 * 1000
        let cutoffBucket = Int((cutoffMs + tzMs) / 60000)

        switch CleanupMode(rawValue: settings.cleanupModeRaw) ?? .manualNotification {
        case .automatic:
            self.autoCleanup(persistence: persistence, cutoffMs: cutoffMs, cutoffBucket: cutoffBucket)
        case .manualNotification:
            self.remindIfOverdue(persistence: persistence, cutoffMs: cutoffMs,
                                 cutoffBucket: cutoffBucket, retentionDays: retentionDays)
        }
    }

    /// Automatic mode: delete expired rows and log the outcome.
    private func autoCleanup(persistence: HistoryPersistence, cutoffMs: Int64, cutoffBucket: Int) {
        persistence.pruneExpired(cutoffMs: cutoffMs, cutoffBucket: cutoffBucket) { deleted in
            guard deleted > 0 else { return }
            let time = ISO8601DateFormatter().string(from: Date())
            Log.settings.info("auto cleanup: removed \(deleted) rows at \(time)")
        }
    }

    /// Manual mode: post a reminder if any expired rows exist.
    private func remindIfOverdue(persistence: HistoryPersistence,
                                 cutoffMs: Int64, cutoffBucket: Int,
                                 retentionDays: Int) {
        persistence.expiredRowCount(cutoffMs: cutoffMs, cutoffBucket: cutoffBucket) { [weak self] count in
            guard count > 0 else { return }
            self?.postReminder(count: count, retentionDays: retentionDays)
        }
    }

    private func postReminder(count: Int, retentionDays: Int) {
        // Reminder body: overdue row count + where to act (Settings). The row
        // count is fetched at fire time, so each daily nudge is accurate.
        let content = UNMutableNotificationContent()
        content.title = Loc.l("Data retention overdue")
        content.body = String(
            format: Loc.l("%ld records exceed the %ld-day retention window. Open Settings to clean them or raise the retention days."),
            count, retentionDays
        )
        content.sound = .default
        // Body click → settings window, storage pane (routed by the app
        // delegate's didReceive handler).
        content.userInfo = [LocalNotification.routeKey: LocalNotification.Route.settingsStorage]
        let request = UNNotificationRequest(
            identifier: "data-retention-reminder",
            content: content,
            trigger: nil
        )
        // The reminder repeats daily by design, so there is no dedup to protect
        // here — it just must not look like a success when the system refused it.
        LocalNotification.deliver(request) { delivered in
            Log.settings.info("retention reminder: \(count) rows overdue, delivered=\(delivered)")
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
