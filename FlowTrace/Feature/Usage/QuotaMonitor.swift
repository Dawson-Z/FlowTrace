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

    init(settings: SettingsStore = .shared,
         aggregator: UsageAggregator = SharedStore.usageAggregator,
         defaults: UserDefaults = .standard,
         deliver: @escaping NotificationDelivery = LocalNotification.deliver) {
        self.settings = settings
        self.aggregator = aggregator
        self.defaults = defaults
        self.deliver = deliver
        self.firedKeys = Set(defaults.stringArray(forKey: Self.firedKeysDefaultsKey) ?? [])

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
        for threshold in config.thresholds {
            let key = "\(periodKey):\(threshold)"
            guard Self.shouldFire(prev: prev, current: current, threshold: threshold,
                                  key: key, alreadyFired: firedKeys) else { continue }
            // A refused attempt is not recorded as fired, so it can be retried
            // — but not on every check, or a denied install would attempt and
            // log on every frame.
            if let next = retryAfter[key], now < next { continue }
            postNotification(threshold: threshold,
                             usedBytes: Int(current / 100.0 * Double(config.limitBytes)),
                             limitBytes: config.limitBytes) { [weak self] delivered in
                guard let self else { return }
                guard delivered else {
                    // Leave the threshold unarmed so a later check retries it.
                    self.retryAfter[key] = Date().addingTimeInterval(Self.failedAttemptBackoff)
                    return
                }
                self.retryAfter[key] = nil
                self.firedKeys.insert(key)
                self.defaults.set(Array(self.firedKeys).sorted(), forKey: Self.firedKeysDefaultsKey)
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

    // MARK: - Notification

    /// Build and hand over one threshold notification. `completion` reports
    /// whether the system actually accepted it — the caller only records the
    /// threshold as fired when it did.
    private func postNotification(threshold: Int, usedBytes: Int, limitBytes: Int,
                                  completion: @escaping (Bool) -> Void) {
        let used = ByteFormatter.string(bytes: usedBytes)
        let limit = ByteFormatter.string(bytes: limitBytes)
        let content = UNMutableNotificationContent()
        content.title = Loc.l("Quota threshold reached")
        content.body = String(
            format: Loc.l("Used %1$@ of %2$@ (%3$ld%%)"),
            used, limit, threshold
        )
        content.sound = .default
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
    /// fresh baseline.
    func resetFiredKeys() {
        firedKeys = []
        retryAfter = [:]
        prevPercent = nil
        defaults.removeObject(forKey: Self.firedKeysDefaultsKey)
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
