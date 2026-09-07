//
//  QuotaMonitor.swift
//  iTrafficPlus — Feature/Usage
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
    private var cancellables: Set<AnyCancellable> = []
    private var prevPercent: Double?

    private static let firedKeysDefaultsKey = "quotaFiredKeys"

    init(settings: SettingsStore = .shared,
         aggregator: UsageAggregator = SharedStore.usageAggregator,
         defaults: UserDefaults = .standard) {
        self.settings = settings
        self.aggregator = aggregator
        self.defaults = defaults
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
        let used: UsageBytes
        switch config.period {
        case "day":   used = aggregator.today
        case "week":  used = aggregator.week
        default:      used = aggregator.month
        }
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
        for threshold in config.thresholds where current >= Double(threshold) {
            let key = "\(periodKey):\(threshold)"
            guard !firedKeys.contains(key), prev < Double(threshold) else { continue }
            fire(threshold: threshold, usedBytes: Int(current / 100.0 * Double(config.limitBytes)),
                 limitBytes: config.limitBytes)
            firedKeys.insert(key)
            defaults.set(Array(firedKeys).sorted(), forKey: Self.firedKeysDefaultsKey)
        }
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

    private func fire(threshold: Int, usedBytes: Int, limitBytes: Int) {
        let center = UNUserNotificationCenter.current()
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
        center.add(request)
    }

    /// Request notification authorization (call when the user enables quota).
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Forget every fired (period, threshold) key and re-arm prevPercent, so
    /// the Settings "Clear data" action lets thresholds notify again from a
    /// fresh baseline.
    func resetFiredKeys() {
        firedKeys = []
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
