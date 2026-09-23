//
//  ProcessAlertMonitor.swift
//  FlowTrace — Feature/Usage
//
//  Per-process daily traffic alerts. A direction (download / upload) fires
//  independently when BOTH hold for one process:
//    1. the process's cumulative bytes today reach the configured floor
//       (per-direction MB floor), and
//    2. today's bytes exceed the process's 7-day daily-median baseline by
//       the configured factor (per-direction multiplier). A zero/missing
//       baseline (brand-new or dormant process) counts as "any traffic is
//       abnormal", so the floor alone gates the alert.
//
//  Delivery rule: at most ONE alert per process per direction per local
//  day. The dedup lives in the `process_alert` table's unique index
//  (day, name_key, direction) — INSERT OR IGNORE returning inserted=false
//  means "already alerted today", which also survives restarts for free.
//  Every accepted insert is an alert-log record shown in the history
//  window's alert tab.
//
//  Baseline: daily totals for the 7 COMPLETE days before today, read from
//  the `process_usage` minute table (missing days count as 0), median per
//  direction. Reloaded at startup and on local-day rollover.
//

import Foundation
import UserNotifications

final class ProcessAlertMonitor {

    private struct DirectionTotal {
        var inBytes: Int = 0
        var outBytes: Int = 0
    }

    private struct Baseline {
        var inMedian: Int = 0
        var outMedian: Int = 0
    }

    private let settings: SettingsStore
    private let deliver: NotificationDelivery
    private let queue = DispatchQueue(label: "process-alert-monitor", qos: .utility)

    // Main-queue state (fed from the frame handler).
    private var currentDay: Int
    private var accum: [String: DirectionTotal] = [:]   // nameKey -> today's totals
    private var baselines: [String: Baseline] = [:]     // nameKey -> 7-day medians
    private var lastCheckAt: Date?
    /// Only checked every `checkInterval` seconds — byte floors are MB-scale,
    /// so per-frame evaluation buys nothing.
    private let checkInterval: TimeInterval = 60

    /// Alerts whose delivery was refused, keyed `"<nameKey>:<direction>"`, so
    /// they can be retried without attempting (and logging) on every check.
    /// In-memory on purpose: a restart retries immediately, which is what we
    /// want once the user fixes the permission.
    private var retryAfter: [String: Date] = [:]
    private static let failedAttemptBackoff: TimeInterval = 15 * 60

    init(settings: SettingsStore = .shared,
         deliver: @escaping NotificationDelivery = LocalNotification.deliver) {
        self.settings = settings
        self.deliver = deliver
        self.currentDay = ProcessAlertMonitor.dayOrdinal(Date())
    }

    /// Seed today's accumulator from the minute table after launch, then
    /// load baselines. Call once after persistence is attached.
    func bootstrap() {
        guard let persistence = SharedStore.historyPersistence else { return }
        let today = currentDay
        persistence.todayProcessTotals(fromBucket: today * 1440) { [weak self] totals in
            guard let self else { return }
            for (key, t) in totals {
                self.accum[key] = DirectionTotal(inBytes: t.in, outBytes: t.out)
            }
            self.reloadBaselines(day: today)
        }
    }

    /// Feed one frame. Called from the nettop frame handler (main queue).
    func feed(entities: [ProcessEntity], interval: Int, now: Date) {
        guard settings.uploadAlertEnabled, interval > 0 else { return }

        let day = Self.dayOrdinal(now)
        if day != currentDay {
            currentDay = day
            accum = [:]
            reloadBaselines(day: day)
        }

        for entity in entities {
            let key = entity.name.lowercased()
            var total = accum[key] ?? DirectionTotal()
            total.inBytes += entity.inBytesPerSec * interval
            total.outBytes += entity.outBytesPerSec * interval
            accum[key] = total
        }

        if let last = lastCheckAt, now.timeIntervalSince(last) < checkInterval { return }
        lastCheckAt = now
        check()
    }

    // MARK: - Decision (pure, testable)

    struct Decision: Equatable {
        let shouldAlert: Bool
        let todayBytes: Int
        let baselineBytes: Int
        let multiplier: Double   // today/baseline; 0 when baseline is 0
    }

    static func decide(todayBytes: Int, baselineBytes: Int,
                       floorBytes: Int, multiplier: Int) -> Decision {
        let floorOk = todayBytes >= floorBytes
        // Zero baseline: any traffic above the floor is "abnormal" (factor ∞).
        let factorOk = baselineBytes <= 0 || Double(todayBytes) >= Double(baselineBytes) * Double(multiplier)
        let factor = baselineBytes > 0 ? Double(todayBytes) / Double(baselineBytes) : 0
        return Decision(shouldAlert: floorOk && factorOk,
                        todayBytes: todayBytes,
                        baselineBytes: baselineBytes,
                        multiplier: factor)
    }

    // MARK: - Check

    private func check() {
        guard let persistence = SharedStore.historyPersistence else { return }
        let day = currentDay
        let minInBytes = max(1, settings.alertMinDownloadMB) * 1024 * 1024
        let minOutBytes = max(1, settings.alertMinUploadMB) * 1024 * 1024

        for (key, total) in accum {
            let base = baselines[key] ?? Baseline()

            let down = Self.decide(todayBytes: total.inBytes, baselineBytes: base.inMedian,
                                   floorBytes: minInBytes, multiplier: max(1, settings.alertDownloadMultiplier))
            if down.shouldAlert {
                fire(persistence: persistence, day: day, nameKey: key, direction: "in",
                     todayBytes: down.todayBytes, baselineBytes: down.baselineBytes, multiplier: down.multiplier)
            }

            let up = Self.decide(todayBytes: total.outBytes, baselineBytes: base.outMedian,
                                 floorBytes: minOutBytes, multiplier: max(1, settings.alertUploadMultiplier))
            if up.shouldAlert {
                fire(persistence: persistence, day: day, nameKey: key, direction: "out",
                     todayBytes: up.todayBytes, baselineBytes: up.baselineBytes, multiplier: up.multiplier)
            }
        }
    }

    private func fire(persistence: HistoryPersistence, day: Int, nameKey: String,
                      direction: String, todayBytes: Int, baselineBytes: Int, multiplier: Double) {
        // Deliver *before* writing the dedup row.
        //
        // The `process_alert` row is the storage-level "already alerted today"
        // marker (see the class comment). Writing it first would mean a refused
        // delivery still silences this process for the rest of the day — the
        // user is never told and never retried. So the row is written only once
        // the system has actually accepted the notification.
        let alertKey = "\(nameKey):\(direction)"
        if let next = retryAfter[alertKey], Date() < next { return }

        postNotification(nameKey: nameKey, isIn: direction == "in",
                         todayBytes: todayBytes, baselineBytes: baselineBytes) { [weak self] delivered in
            guard let self else { return }
            guard delivered else {
                self.retryAfter[alertKey] = Date().addingTimeInterval(Self.failedAttemptBackoff)
                return
            }
            self.retryAfter[alertKey] = nil
            let row = ProcessAlertRow(
                day: day,
                name: nameKey,
                nameKey: nameKey,
                direction: direction,
                todayBytes: todayBytes,
                baselineBytes: baselineBytes,
                multiplier: multiplier,
                ts: Int64(Date().timeIntervalSince1970 * 1000)
            )
            persistence.appendProcessAlert(row) { _ in
                // `inserted == false` means another writer got there first
                // between our check and now; the notification is already out,
                // so there is nothing further to do.
            }
        }
    }

    private func postNotification(nameKey: String, isIn: Bool, todayBytes: Int, baselineBytes: Int,
                                  completion: @escaping (Bool) -> Void) {
        let dirWord = isIn ? Loc.l("download") : Loc.l("upload")
        let dir = direction(isIn)
        let content = UNMutableNotificationContent()
        content.title = Loc.l("Unusual traffic")
        let volume = ByteFormatter.string(bytes: todayBytes)
        // Arg order: 1 name, 2 direction, 3 volume, 4 factor (baseline variant only).
        let body: String
        if baselineBytes > 0 {
            body = String(
                format: Loc.l("%1$@ today %2$@ %3$@, %4$.1f× its 7-day daily median."),
                nameKey, dirWord, volume, todayBytes > 0 ? Double(todayBytes) / Double(baselineBytes) : 0
            )
        } else {
            body = String(
                format: Loc.l("%1$@ today %2$@ %3$@ (no 7-day baseline)."),
                nameKey, dirWord, volume
            )
        }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "process-alert-\(currentDay)-\(nameKey)-\(isIn ? "in" : "out")",
            content: content,
            trigger: nil
        )
        deliver(request) { delivered in
            Log.settings.info(
                "process alert: \(nameKey) \(dir) \(todayBytes)B vs median \(baselineBytes)B delivered=\(delivered)"
            )
            completion(delivered)
        }
    }

    private func direction(_ isIn: Bool) -> String { isIn ? "in" : "out" }

    // MARK: - Baseline

    /// Reload the 7 complete days before `day` from the minute table
    /// (missing days count as 0) and store per-direction medians.
    private func reloadBaselines(day: Int) {
        guard let persistence = SharedStore.historyPersistence else { return }
        let fromBucket = (day - 7) * 1440
        let toBucket = day * 1440
        persistence.dailyProcessTotals(fromBucket: fromBucket, toBucket: toBucket) { [weak self] totals in
            guard let self else { return }
            var result: [String: Baseline] = [:]
            for (key, perDay) in totals {
                let ins = (0..<7).map { perDay[day - 7 + $0]?.in ?? 0 }
                let outs = (0..<7).map { perDay[day - 7 + $0]?.out ?? 0 }
                result[key] = Baseline(inMedian: Self.median(ins), outMedian: Self.median(outs))
            }
            self.baselines = result
        }
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Forget all in-memory state (clear-data action). The on-disk alert
    /// log is wiped by the persistence layer, so the unique-index dedup
    /// resets with it.
    func reset() {
        queue.async { [weak self] in
            self?.lastCheckAt = nil
        }
        accum = [:]
        baselines = [:]
        retryAfter = [:]
        currentDay = Self.dayOrdinal(Date())
    }

    static func dayOrdinal(_ date: Date) -> Int {
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        return Int((date.timeIntervalSince1970 + tz) / 86400)
    }
}
