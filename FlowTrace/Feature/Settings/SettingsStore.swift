//
//  SettingsStore.swift
//  FlowTrace — Feature/Settings
//
//  ObservableObject over `UserDefaults` for runtime-tweakable preferences.
//  Using `UserDefaults.standard` rather than a hand-rolled plist so the
//  user gets the standard macOS `defaults read/write` CLI for free:
//
//      defaults read local.FlowTrace launchAtLogin
//      defaults write local.FlowTrace launchAtLogin -bool YES
//
//  Storage pattern
//  ---------------
//  We use Swift's `@Published` + a Combine `sink` on `$prop.dropFirst()`
//  rather than `didSet` for the write path. The reason is that `didSet`
//  fires during `init`'s seeded-assignment step, which would write back
//  whatever was already on disk, logging a spurious "user changed this"
//  to the defaults system. Dropping the first value from the publisher
//  skips that initial emission, so the sink only fires on a real user
//  edit from the Settings window.
//

import Foundation
import Combine
import SwiftUI
import AppKit

/// How out-of-retention history data is handled at the daily checkpoint.
/// `manualNotification` nudges the user to clear it; `automatic` deletes it
/// on its own. Stored as a string in UserDefaults.
enum CleanupMode: String, CaseIterable, Identifiable {
    case manualNotification
    case automatic

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .manualNotification: return "Cleanup mode manual"
        case .automatic:          return "Cleanup mode automatic"
        }
    }

    /// New installs default to nudging the user (never surprise-delete).
    static var defaultMode: CleanupMode { .manualNotification }
}

/// App-wide appearance choice, persisted as a string in UserDefaults.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .system: return "Follow system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// The accent colour has its own subsystem — model, persistence, settings
/// UI and environment integration live in
/// `Feature/Appearance/AccentColor.swift` (`AccentColorManager`). This
/// store owns no accent keys.

final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    /// Guards the launch-at-login rollback path so setting `launchAtLogin
    /// = false` inside the sink does not re-enter the sink and loop.
    private var isRollingBackLaunchAtLogin = false

    // MARK: - General

    @Published var launchAtLogin: Bool
    /// Default sort mode for the process list. Maps to `ListSortMode.rawValue`.
    @Published var defaultSortModeRaw: String

    // MARK: - Appearance

    /// Overall app appearance: follow system / light / dark.
    @Published var appearanceRaw: String

    // MARK: - Status bar

    @Published var showDownloadInStatusBar: Bool
    @Published var showUploadInStatusBar: Bool

    // MARK: - History / data retention

    /// Days to keep rows in history.sqlite3. Positive integer; no upper cap
    /// (a generous ceiling is enforced in the UI). New installs default to
    /// 30 days; existing users keep whatever was already saved.
    @Published var historyRetentionDays: Int
    /// Cleanup strategy once data ages past the retention window.
    @Published var cleanupModeRaw: String
    /// Local time-of-day (seconds since midnight) at which the daily
    /// retention checkpoint runs — either automatic cleanup or a reminder.
    @Published var retentionTimeOfDay: Int

    // MARK: - Monitoring

    /// nettop sample interval in seconds. Fixed at 1 s to match Activity
    /// Monitor's default refresh; the settings UI no longer offers a choice
    /// (a configurable interval was milestone 11, removed per user request).
    /// Applies to all nettop subprocesses.
    let refreshInterval: Int = 1

    // MARK: - Localization

    /// Manual language override. `nil` = follow the system. One of
    /// "zh-Hans" / "en" / "zh-Hant". Read by `LocalizationManager` to pick
    /// the `.lproj` bundle; changing it repaints the UI immediately.
    @Published var languageOverride: String?

    // MARK: - Quota

    /// Master switch for quota alerts. Turning it on requests notification
    /// authorization (handled in the settings binding layer).
    @Published var quotaEnabled: Bool
    /// Quota period: "month" / "week" / "day" (month default).
    @Published var quotaPeriod: String
    /// Quota limit in GB (1…10000).
    @Published var quotaLimitGB: Int
    /// Extra custom threshold percent (0 = off; 80/100 always on).
    @Published var quotaCustomPercent: Int

    // MARK: - Menu bar totals

    /// Show today's accumulated total in the menu bar.
    @Published var showTodayInMenuBar: Bool
    /// Show the quota period's accumulated total in the menu bar. The period
    /// itself is `quotaPeriod` (day / week / month), so this segment answers
    /// the same question the quota alerts do. Named "period" rather than
    /// "month" since that rename — the old, month-only key is migrated in
    /// `migrateRenamedDefaultsKeysIfNeeded`.
    @Published var showPeriodInMenuBar: Bool
    /// Show the app mark in the menu bar. Forced on (and the Settings toggle
    /// disabled) while every other segment is off, so the item never becomes
    /// an empty slot; with any other segment visible it is a free choice.
    /// Defaults to off.
    @Published var showLogoInMenuBar: Bool

    // MARK: - Popover modules
    //
    // Which modules the popover window renders. All default to on — these
    // exist to let the user de-clutter, not to hide features by surprise.

    /// The searchable process list (search bar + column headers + rows).
    @Published var showProcessListInPopover: Bool
    /// The per-interface-category summary above the sparkline.
    @Published var showInterfacesInPopover: Bool
    /// The 60-sample sparkline and its "last 2 min" caption row.
    @Published var showSparklineInPopover: Bool
    /// The "today peak" figures row inside the history block.
    @Published var showTodayPeakInPopover: Bool
    /// The "Today ∑" figures row inside the history block.
    @Published var showTodayTotalInPopover: Bool
    /// The accent "Open history statistics" button (with its divider).
    @Published var showHistoryEntryInPopover: Bool

    // MARK: - Process traffic alerts

    /// Master switch for per-process traffic alerts.
    @Published var uploadAlertEnabled: Bool
    /// Alert when a process's daily download reaches the floor AND exceeds
    /// its 7-day daily-median baseline by this factor.
    @Published var alertDownloadMultiplier: Int
    /// Same, for the upload direction.
    @Published var alertUploadMultiplier: Int
    /// Absolute daily floor (MB) below which a download never alerts.
    @Published var alertMinDownloadMB: Int
    /// Same, for the upload direction.
    @Published var alertMinUploadMB: Int

    private enum K {
        static let launchAtLogin              = "launchAtLogin"
        static let defaultSortModeRaw         = "defaultSortModeRaw"
        static let appearanceRaw              = "appearanceRaw"
        // Accent storage lives in `AccentColorManager`
        // (Feature/Appearance/AccentColor.swift); no keys here.
        static let showDownloadInStatusBar    = "showDownloadInStatusBar"
        static let showUploadInStatusBar      = "showUploadInStatusBar"
        static let historyRetentionDays       = "historyRetentionDays"
        static let cleanupMode                = "cleanupMode"
        static let retentionTimeOfDay         = "retentionTimeOfDay"
        static let languageOverride           = "languageOverride"
        static let quotaEnabled               = "quotaEnabled"
        static let quotaPeriod                = "quotaPeriod"
        static let quotaLimitGB               = "quotaLimitGB"
        static let quotaCustomPercent         = "quotaCustomPercent"
        static let showTodayInMenuBar         = "showTodayInMenuBar"
        static let showPeriodInMenuBar        = "showPeriodInMenuBar"
        static let showLogoInMenuBar          = "showLogoInMenuBar"
        static let showProcessListInPopover   = "showProcessListInPopover"
        static let showInterfacesInPopover    = "showInterfacesInPopover"
        static let showSparklineInPopover     = "showSparklineInPopover"
        static let showTodayPeakInPopover     = "showTodayPeakInPopover"
        static let showTodayTotalInPopover    = "showTodayTotalInPopover"
        static let showHistoryEntryInPopover  = "showHistoryEntryInPopover"
        static let uploadAlertEnabled         = "uploadAlertEnabled"
        static let alertDownloadMultiplier    = "alertDownloadMultiplier"
        static let alertUploadMultiplier      = "alertUploadMultiplier"
        static let alertMinDownloadMB         = "alertMinDownloadMB"
        static let alertMinUploadMB           = "alertMinUploadMB"
    }

    /// One-time rename of persisted keys whose meaning changed.
    ///
    /// Applied only when the new key is absent, so a value the user has set
    /// under the new name is never overwritten; the old key is removed at the
    /// same time so this cannot re-run against a stale copy. Runs before the
    /// `@Published` seeding, which therefore reads the migrated value.
    private static func migrateRenamedDefaultsKeysIfNeeded(into defaults: UserDefaults) {
        let renames = [
            // The menu-bar segment stopped being "this calendar month" and
            // became "the quota period", which may be a day or a week.
            ("showMonthInMenuBar", "showPeriodInMenuBar"),
        ]
        for (old, new) in renames {
            guard defaults.object(forKey: new) == nil,
                  let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
            defaults.removeObject(forKey: old)
            Log.settings.info("[migration] renamed defaults key \(old) -> \(new)")
        }
    }

    init(defaults: UserDefaults = .standard) {
        Self.migrateRenamedDefaultsKeysIfNeeded(into: defaults)
        self.defaults = defaults
        // Read directly into backing storage; this bypasses the @Published
        // publishers' willChange and does not fire the `sink`s below.
        //
        // `launchAtLogin` is seeded from the *live* OS status (not from the
        // defaults value) because the macOS login-item state is the source of
        // truth: UserDefaults can drift when the user manages it in System
        // Settings (macOS 13+), and on 11–12 the manager reads the launchd
        // agent it owns instead.
        let launchStatus = LaunchAtLoginManager.currentStatus()
        self._launchAtLogin           = Published(initialValue: launchStatus == .enabled)
        self._defaultSortModeRaw      = Published(initialValue: defaults.string(forKey: K.defaultSortModeRaw) ?? "download")
        self._appearanceRaw           = Published(initialValue: defaults.string(forKey: K.appearanceRaw) ?? AppearanceMode.system.rawValue)
        self._showDownloadInStatusBar = Published(initialValue: defaults.object(forKey: K.showDownloadInStatusBar) as? Bool ?? true)
        self._showUploadInStatusBar   = Published(initialValue: defaults.object(forKey: K.showUploadInStatusBar) as? Bool ?? true)
        self._historyRetentionDays    = Published(initialValue: defaults.object(forKey: K.historyRetentionDays) as? Int ?? 30)
        self._cleanupModeRaw          = Published(initialValue: defaults.string(forKey: K.cleanupMode) ?? CleanupMode.defaultMode.rawValue)
        self._retentionTimeOfDay      = Published(initialValue: defaults.object(forKey: K.retentionTimeOfDay) as? Int ?? 12 * 3600)
        self._languageOverride        = Published(initialValue: defaults.string(forKey: K.languageOverride))
        self._quotaEnabled            = Published(initialValue: defaults.object(forKey: K.quotaEnabled) as? Bool ?? false)
        self._quotaPeriod             = Published(initialValue: defaults.string(forKey: K.quotaPeriod) ?? "month")
        self._quotaLimitGB            = Published(initialValue: defaults.object(forKey: K.quotaLimitGB) as? Int ?? 100)
        self._quotaCustomPercent      = Published(initialValue: defaults.object(forKey: K.quotaCustomPercent) as? Int ?? 0)
        self._showTodayInMenuBar      = Published(initialValue: defaults.object(forKey: K.showTodayInMenuBar) as? Bool ?? false)
        self._showPeriodInMenuBar     = Published(initialValue: defaults.object(forKey: K.showPeriodInMenuBar) as? Bool ?? false)
        self._showLogoInMenuBar       = Published(initialValue: defaults.object(forKey: K.showLogoInMenuBar) as? Bool ?? false)
        self._showProcessListInPopover  = Published(initialValue: defaults.object(forKey: K.showProcessListInPopover) as? Bool ?? true)
        self._showInterfacesInPopover   = Published(initialValue: defaults.object(forKey: K.showInterfacesInPopover) as? Bool ?? true)
        self._showSparklineInPopover    = Published(initialValue: defaults.object(forKey: K.showSparklineInPopover) as? Bool ?? true)
        self._showTodayPeakInPopover    = Published(initialValue: defaults.object(forKey: K.showTodayPeakInPopover) as? Bool ?? true)
        self._showTodayTotalInPopover   = Published(initialValue: defaults.object(forKey: K.showTodayTotalInPopover) as? Bool ?? true)
        self._showHistoryEntryInPopover = Published(initialValue: defaults.object(forKey: K.showHistoryEntryInPopover) as? Bool ?? true)
        self._uploadAlertEnabled      = Published(initialValue: defaults.object(forKey: K.uploadAlertEnabled) as? Bool ?? false)
        self._alertDownloadMultiplier = Published(initialValue: defaults.object(forKey: K.alertDownloadMultiplier) as? Int ?? 10)
        self._alertUploadMultiplier   = Published(initialValue: defaults.object(forKey: K.alertUploadMultiplier) as? Int ?? 10)
        self._alertMinDownloadMB      = Published(initialValue: defaults.object(forKey: K.alertMinDownloadMB) as? Int ?? 500)
        self._alertMinUploadMB        = Published(initialValue: defaults.object(forKey: K.alertMinUploadMB) as? Int ?? 500)

        // Each sink starts with the just-loaded value; `.dropFirst()` skips
        // that initial replay, so only real user edits round-trip to disk.
        //
        // `launchAtLogin` does NOT write to UserDefaults — the OS login-item
        // state is authoritative. The sink calls the manager instead.
        $launchAtLogin
            .dropFirst()
            .sink { [weak self] v in
                guard let self = self, !self.isRollingBackLaunchAtLogin else { return }
                let status = LaunchAtLoginManager.setEnabled(v)
                if case .failed(let msg) = status {
                    // Registration failed. Roll the toggle back so the UI
                    // does not lie about the actual system state; the guard
                    // flag prevents the rollback write from re-firing the
                    // sink and looping.
                    self.isRollingBackLaunchAtLogin = true
                    self.launchAtLogin = false
                    self.isRollingBackLaunchAtLogin = false
                    Log.settings.error("launch-at-login toggle failed: \(msg)")
                }
            }
            .store(in: &cancellables)
        $defaultSortModeRaw.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.defaultSortModeRaw) }
            .store(in: &cancellables)
        $appearanceRaw.dropFirst()
            .sink { [weak self] v in
                self?.defaults.set(v, forKey: K.appearanceRaw)
                // Defer to the next runloop tick: this sink runs inside the
                // Picker's binding-update pass, and an appearance change
                // issued mid-pass gets coalesced away by AppKit (observed as
                // "the UI lags one selection behind"). A fresh event applies
                // it reliably.
                DispatchQueue.main.async {
                    self?.applyAppearance()
                }
            }
            .store(in: &cancellables)
        // Accent persistence sinks live in `AccentColorManager`; nothing
        // to persist here.
        $showDownloadInStatusBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showDownloadInStatusBar) }
            .store(in: &cancellables)
        $showUploadInStatusBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showUploadInStatusBar) }
            .store(in: &cancellables)
        $historyRetentionDays.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.historyRetentionDays) }
            .store(in: &cancellables)
        $cleanupModeRaw.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.cleanupMode) }
            .store(in: &cancellables)
        $retentionTimeOfDay.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.retentionTimeOfDay) }
            .store(in: &cancellables)
        $languageOverride.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.languageOverride) }
            .store(in: &cancellables)
        $quotaEnabled.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.quotaEnabled) }
            .store(in: &cancellables)
        $quotaPeriod.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.quotaPeriod) }
            .store(in: &cancellables)
        $quotaLimitGB.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.quotaLimitGB) }
            .store(in: &cancellables)
        $quotaCustomPercent.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.quotaCustomPercent) }
            .store(in: &cancellables)
        $showTodayInMenuBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showTodayInMenuBar) }
            .store(in: &cancellables)
        $showPeriodInMenuBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showPeriodInMenuBar) }
            .store(in: &cancellables)
        $showLogoInMenuBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showLogoInMenuBar) }
            .store(in: &cancellables)
        $showProcessListInPopover.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showProcessListInPopover) }
            .store(in: &cancellables)
        $showInterfacesInPopover.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showInterfacesInPopover) }
            .store(in: &cancellables)
        $showSparklineInPopover.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showSparklineInPopover) }
            .store(in: &cancellables)
        $showTodayPeakInPopover.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showTodayPeakInPopover) }
            .store(in: &cancellables)
        $showTodayTotalInPopover.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showTodayTotalInPopover) }
            .store(in: &cancellables)
        $showHistoryEntryInPopover.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showHistoryEntryInPopover) }
            .store(in: &cancellables)
        $uploadAlertEnabled.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.uploadAlertEnabled) }
            .store(in: &cancellables)
        $alertDownloadMultiplier.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.alertDownloadMultiplier) }
            .store(in: &cancellables)
        $alertUploadMultiplier.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.alertUploadMultiplier) }
            .store(in: &cancellables)
        $alertMinDownloadMB.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.alertMinDownloadMB) }
            .store(in: &cancellables)
        $alertMinUploadMB.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.alertMinUploadMB) }
            .store(in: &cancellables)

        // Launch: apply the saved appearance immediately (the sink above
        // only fires on later edits).
        applyAppearance()
    }

    /// Push the saved appearance to `NSApp.appearance`. This is the standard
    /// AppKit runtime-appearance mechanism: the change propagates to every
    /// window (title bars, standard controls, NSHostingView content and all
    /// dynamic colours) with no extra plumbing. `nil` = follow the system.
    /// Called from the `$appearanceRaw` sink and once at launch.
    func applyAppearance() {
        let mode = AppearanceMode(rawValue: appearanceRaw) ?? .system
        switch mode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // The popover's window is created on first show and then CACHED (kept
        // as a status-bar child window). Unlike normal windows it does not
        // reliably repaint on NSApp.appearance changes while cached, so pin
        // its appearance explicitly whenever it exists. AppDelegate.popover
        // is nil until the popover is created in applicationDidFinishLaunching
        // (which can run AFTER this store's init), hence the nil checks.
        if let popover = AppDelegate.popover,
           let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.appearance = NSApp.appearance
        }
        Log.settings.info("[appearance] applied mode=\(mode.rawValue)")
    }
}
