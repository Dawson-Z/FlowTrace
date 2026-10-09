//
//  QuotaMonitor.swift
//  FlowTrace — Feature/Usage
//
//  Watches the shared UsageAggregator and fires a local notification once
//  per (period, threshold) crossing. Dedup keys are stored in UserDefaults
//  and keyed by the period's start date, so a new period automatically
//  re-arms every threshold.
//
//  Detection rule: fire when prevPercent < t AND currentPercent >= t. The
//  first observation after launch initialises prevPercent without firing.
//

import Foundation
import Combine
import UserNotifications

final class QuotaMonitor: ObservableObject {

    /// Period keys already notified, e.g. "2026-09-01:80".
    @Published private(set) var firedKeys: Set<String> = []

    private let settings: SettingsStore
    private let aggregator: UsageAggregator
    private let defaults: UserDefaults
    private let deliver: NotificationDelivery
    private var cancellables: Set<AnyCancellable> = []
    private var prevPercent: Double?

    /// Thresholds whose delivery was refused, keyed like `firedKeys`, so they
    /// can be retried later without retrying (and logging) on every check.
    /// Deliberately in-memory: after a restart we *want* an immediate retry,
    /// which is what happens once the user fixes the permission.
    private var retryAfter: [String: Date] = [:]

    /// Backoff after a refused delivery — long enough that a denied install
    /// does not attempt (and log) on every check, short enough that granting
    /// the permission takes effect the same day.
    private static let failedAttemptBackoff: TimeInterval = 15 * 60

    private static let firedKeysDefaultsKey = "quotaFiredKeys"

    // MARK: 100% growth-driven state (spec §2.2 — see the task PRD)
    //
    // The 80%/custom thresholds stay "once per period" via `firedKeys`. The
    // 100% threshold additionally re-fires while usage keeps growing, unless
    // muted. Bookkeeping:
    //   - `notifiedAtBytes100` — bytes used at the most recent 100% notification,
    //     persisted *with* its period key so a period rollover resets it.
    //   - `mutedUntil100` — in-memory (restart lifts a 1-hour mute, same
    //     philosophy as the 15-minute delivery backoff).
    //   - `mutedDay100` — persisted day key; "Mute today" survives a restart.
    private static let quota100NotifiedPeriodKey = "quota100NotifiedPeriod"
    private static let quota100NotifiedBytesKey = "quota100NotifiedBytes"
    private static let quota100MutedDayKey = "quota100MutedDay"

    @Published private(set) var notifiedAtBytes100: Int?
    @Published private(set) var mutedUntil100: Date?
    @Published private(set) var mutedDay100: String?

    init(settings: SettingsStore = .shared,
         aggregator: UsageAggregator = SharedStore.usageAggregator,
         defaults: UserDefaults = .standard,
         deliver: @escaping NotificationDelivery = LocalNotification.deliver) {
        self.settings = settings
        self.aggregator = aggregator
        self.defaults = defaults
        self.deliver = deliver
        self.firedKeys = Set(defaults.stringArray(forKey: Self.firedKeysDefaultsKey) ?? [])
        self.mutedDay100 = defaults.string(forKey: Self.quota100MutedDayKey)

        // Only observe usage while the feature is enabled; rewire on toggle.
        settings.$quotaEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.cancellables.subtract(self.usageCancellables)
                guard enabled else { return }
                self.observeUsage()
            }
            .store(in: &cancellables)
    }

    /// Install the observation at launch.
    ///
    /// `SharedStore.quotaMonitor` is a lazily-initialised `static let`, so its
    /// `init` — and therefore its subscription to `settings.$quotaEnabled` and
    /// `aggregator.$today/week/month` — does not run until something touches
    /// the instance. Nothing in the launch path used to, which meant `check()`
    /// was never called and the quota feature never fired at all. Called from
    /// `AppDelegate.applicationDidFinishLaunching`, next to
    /// `ProcessAlertMonitor.bootstrap()`.
    func bootstrap() {
        guard settings.quotaEnabled else { return }
        check()
    }

    private var usageCancellables: Set<AnyCancellable> = []

    private func observeUsage() {
        aggregator.$today
            .combineLatest(aggregator.$week, aggregator.$month)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.check()
            }
            .store(in: &usageCancellables)
    }

    // MARK: - Threshold logic (pure, testable)

    struct QuotaConfig: Equatable {
        let enabled: Bool
        let period: String      // "month" / "week" / "day"
        let limitBytes: Int
        let thresholds: [Int]   // percent values, unique, sorted
    }

    func config() -> QuotaConfig {
        var thresholds: Set<Int> = [80, 100]
        let custom = settings.quotaCustomPercent
        if custom > 0 && custom < 100 { thresholds.insert(custom) }
        return QuotaConfig(
            enabled: settings.quotaEnabled,
            period: settings.quotaPeriod,
            limitBytes: max(1, settings.quotaLimitGB) * 1024 * 1024 * 1024,
            thresholds: thresholds.sorted()
        )
    }

    /// Current usage percent for the configured period (0…∞, can exceed 100).
    func currentPercent() -> Double {
        let config = config()
        guard config.enabled, !config.thresholds.isEmpty else { return 0 }
        let used = aggregator.bytes(forPeriod: config.period)
        guard config.limitBytes > 0 else { return 0 }
        return Double(used.total) / Double(config.limitBytes) * 100
    }

    func check() {
        let config = config()
        guard config.enabled, config.limitBytes > 0 else { return }

        let current = currentPercent()
        defer { prevPercent = current }
        guard let prev = prevPercent else { return }  // first observation: arm only

        let periodKey = Self.periodStartKey(period: config.period, now: Date())
        let now = Date()
        let usedBytes = Int(current / 100.0 * Double(config.limitBytes))
        for threshold in config.thresholds {
            let key = "\(periodKey):\(threshold)"

            // 100%-only growth branch (spec §2.2): once over 100%, re-fire
            // while usage keeps growing, unless muted. Independent of the
            // crossing path below and of `firedKeys`.
            if threshold == 100 {
                let notified = notifiedAtBytes100(periodKey: periodKey)
                if Self.shouldRefire100(currentPercent: current, now: now,
                                        mutedUntil: mutedUntil100, mutedDay: mutedDay100,
                                        todayKey: Self.periodStartKey(period: "day", now: now),
                                        lastNotifiedBytes: notified,
                                        usedBytes: usedBytes,
                                        incrementBytes: Self.refireIncrementBytes(limit: config.limitBytes)) {
                    if let next = retryAfter[key], now < next { continue }
                    postNotification(threshold: threshold, usedBytes: usedBytes,
                                     limitBytes: config.limitBytes, is100: true) { [weak self] delivered in
                        guard let self else { return }
                        guard delivered else {
                            self.retryAfter[key] = Date().addingTimeInterval(Self.failedAttemptBackoff)
                            return
                        }
                        self.retryAfter[key] = nil
                        self.setNotifiedAtBytes100(usedBytes, periodKey: periodKey)
                    }
                }
            }

            // Crossing path — all thresholds, "once per period" semantics.
            guard Self.shouldFire(prev: prev, current: current, threshold: threshold,
                                  key: key, alreadyFired: firedKeys) else { continue }
            // A refused attempt is not recorded as fired, so it can be retried
            // — but not on every check, or a denied install would attempt and
            // log on every frame.
            if let next = retryAfter[key], now < next { continue }
            postNotification(threshold: threshold, usedBytes: usedBytes,
                             limitBytes: config.limitBytes,
                             is100: threshold == 100) { [weak self] delivered in
                guard let self else { return }
                guard delivered else {
                    // Leave the threshold unarmed so a later check retries it.
                    self.retryAfter[key] = Date().addingTimeInterval(Self.failedAttemptBackoff)
                    return
                }
                self.retryAfter[key] = nil
                self.firedKeys.insert(key)
                self.defaults.set(Array(self.firedKeys).sorted(), forKey: Self.firedKeysDefaultsKey)
                // The first 100% notification also seeds the growth baseline:
                // re-fires require further growth past this point (spec §2.2).
                if threshold == 100 {
                    self.setNotifiedAtBytes100(usedBytes, periodKey: periodKey)
                }
            }
        }
    }

    /// Whether this check should fire `threshold`: the percent must have
    /// crossed it since the previous observation (`prev < t && current >= t`)
    /// and the `(period, threshold)` pair must not have fired already.
    ///
    /// Pure, so the crossing rule is unit-testable without a live aggregator.
    /// Before this existed the rule was only *mirrored* by a standalone script,
    /// which silently drifted from this file whenever the rule changed.
    static func shouldFire(prev: Double, current: Double, threshold: Int,
                           key: String, alreadyFired: Set<String>) -> Bool {
        guard current >= Double(threshold) else { return false }
        guard !alreadyFired.contains(key) else { return false }
        return prev < Double(threshold)
    }

    // MARK: 100% growth re-fire (spec §2.2, pure & testable)

    /// Re-fire the 100% notification: usage is over 100%, not muted, and has
    /// grown past the last-notified point by at least the increment.
    /// `lastNotifiedBytes == nil` means "no 100% notification in this period
    /// yet" — the crossing path owns that first fire, so this returns false.
    static func shouldRefire100(currentPercent: Double, now: Date,
                                mutedUntil: Date?, mutedDay: String?, todayKey: String,
                                lastNotifiedBytes: Int?, usedBytes: Int,
                                incrementBytes: Int) -> Bool {
        guard currentPercent >= 100 else { return false }
        if let until = mutedUntil, now < until { return false }
        if let day = mutedDay, day == todayKey { return false }
        guard let notified = lastNotifiedBytes else { return false }
        return usedBytes >= notified + incrementBytes
    }

    /// Re-fire increment: 1% of the quota. The floor keeps a 1 GB quota from
    /// re-firing on every megabyte.
    static func refireIncrementBytes(limit: Int) -> Int {
        max(1, limit / 100)
    }

    /// Bytes recorded at the most recent 100% notification, or `nil` when the
    /// stored period does not match (rollover / never notified).
    private func notifiedAtBytes100(periodKey: String) -> Int? {
        guard defaults.string(forKey: Self.quota100NotifiedPeriodKey) == periodKey,
              defaults.object(forKey: Self.quota100NotifiedBytesKey) != nil else { return nil }
        return defaults.integer(forKey: Self.quota100NotifiedBytesKey)
    }

    private func setNotifiedAtBytes100(_ bytes: Int, periodKey: String) {
        notifiedAtBytes100 = bytes
        defaults.set(periodKey, forKey: Self.quota100NotifiedPeriodKey)
        defaults.set(bytes, forKey: Self.quota100NotifiedBytesKey)
    }

    // MARK: 100% notification actions (wired from the app delegate)

    /// The action identifier routed from `UNUserNotificationCenterDelegate`.
    /// Unknown identifiers are ignored so future action sets degrade softly.
    func handleQuota100Action(_ identifier: String) {
        switch identifier {
        case LocalNotification.Quota100Action.acknowledge:
            acknowledge100()
        case LocalNotification.Quota100Action.mute1Hour:
            mute100ForOneHour()
        case LocalNotification.Quota100Action.muteToday:
            mute100ForToday()
        default:
            break
        }
    }

    /// "Acknowledge" behaves like dismissing the banner (spec §2.2): no mute —
    /// the growth baseline simply moves to *now*, so only further growth can
    /// re-fire.
    func acknowledge100() {
        let config = config()
        guard config.enabled else { return }
        let percent = currentPercent()
        guard percent >= 100 else { return }
        let used = Int(percent / 100.0 * Double(config.limitBytes))
        setNotifiedAtBytes100(used, periodKey: Self.periodStartKey(period: config.period, now: Date()))
    }

    /// In-memory on purpose: a restart lifts a 1-hour mute, same philosophy
    /// as the 15-minute delivery backoff.
    func mute100ForOneHour() {
        mutedUntil100 = Date().addingTimeInterval(3600)
    }

    /// Persisted: "Mute today" survives a restart — the words promise today,
    /// not "until this process dies".
    func mute100ForToday() {
        let day = Self.periodStartKey(period: "day", now: Date())
        mutedDay100 = day
        defaults.set(day, forKey: Self.quota100MutedDayKey)
    }

    /// ISO date of the current period's start (dedup key root).
    static func periodStartKey(period: String, now: Date) -> String {
        let calendar = Calendar.current
        let start: Date
        switch period {
        case "day":  start = calendar.startOfDay(for: now)
        case "week":
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        default:     // month
            start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? calendar.startOfDay(for: now)
        }
        return ISO8601DateFormatter().string(from: start)
    }

    /// Whole days left in the current period, counting today: the distance
    /// from today's local midnight to the period's end (day → tomorrow,
    /// week → the next week start, month → the 1st). Uses the same period
    /// boundaries as `periodStartKey`, so the popover's "N days left" always
    /// flips to a fresh count exactly when the dedup keys reset. Never below
    /// 1 — today itself still counts while the period is running.
    static func daysRemainingInPeriod(period: String, now: Date,
                                      calendar: Calendar = .current) -> Int {
        let component: Calendar.Component
        switch period {
        case "week":  component = .weekOfYear
        case "month": component = .month
        default:      component = .day
        }
        guard let interval = calendar.dateInterval(of: component, for: now) else { return 1 }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: now),
                                           to: interval.end).day ?? 1
        return max(days, 1)
    }

    // MARK: - Notification

    /// Build and hand over one threshold notification. `completion` reports
    /// whether the system actually accepted it — the caller only records the
    /// threshold as fired when it did. The 100% variant carries the action
    /// category; every quota notification routes its body click to the
    /// settings quota pane.
    private func postNotification(threshold: Int, usedBytes: Int, limitBytes: Int,
                                  is100: Bool, completion: @escaping (Bool) -> Void) {
        let used = ByteFormatter.string(bytes: usedBytes)
        let limit = ByteFormatter.string(bytes: limitBytes)
        let content = UNMutableNotificationContent()
        content.title = Loc.l("Quota threshold reached")
        content.body = String(
            format: Loc.l("Used %1$@ of %2$@ (%3$ld%%)"),
            used, limit, threshold
        )
        content.sound = .default
        content.userInfo = [LocalNotification.routeKey: LocalNotification.Route.settingsQuota]
        if is100 {
            content.categoryIdentifier = LocalNotification.quota100CategoryID
        }
        let request = UNNotificationRequest(
            identifier: "quota-\(Self.periodStartKey(period: settings.quotaPeriod, now: Date()))-\(threshold)",
            content: content,
            trigger: nil
        )
        deliver(request) { delivered in
            Log.settings.info(
                "quota \(threshold)% reached (\(used) of \(limit)); notification delivered=\(delivered)"
            )
            completion(delivered)
        }
    }

    /// Forget every fired (period, threshold) key and re-arm prevPercent, so
    /// the Settings "Clear data" action lets thresholds notify again from a
    /// fresh baseline. The 100% growth state (baseline bytes, both mutes)
    /// resets with it.
    func resetFiredKeys() {
        firedKeys = []
        retryAfter = [:]
        prevPercent = nil
        notifiedAtBytes100 = nil
        mutedUntil100 = nil
        mutedDay100 = nil
        defaults.removeObject(forKey: Self.firedKeysDefaultsKey)
        defaults.removeObject(forKey: Self.quota100NotifiedPeriodKey)
        defaults.removeObject(forKey: Self.quota100NotifiedBytesKey)
        defaults.removeObject(forKey: Self.quota100MutedDayKey)
    }
}

enum ByteFormatter {
    static func string(bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1000 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}
