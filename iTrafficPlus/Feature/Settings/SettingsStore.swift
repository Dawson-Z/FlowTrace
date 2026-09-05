//
//  SettingsStore.swift
//  iTrafficPlus — Feature/Settings
//
//  ObservableObject over `UserDefaults` for runtime-tweakable preferences.
//  Using `UserDefaults.standard` rather than a hand-rolled plist so the
//  user gets the standard macOS `defaults read/write` CLI for free:
//
//      defaults read local.iTrafficPlus launchAtLogin
//      defaults write local.iTrafficPlus launchAtLogin -bool YES
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
    /// Affects the search-bar filter only; the sort comparator in
    /// `ListViewModel.sort` always uses `localizedCaseInsensitiveCompare`.
    @Published var caseInsensitiveSearch: Bool

    // MARK: - Status bar

    @Published var showDownloadInStatusBar: Bool
    @Published var showUploadInStatusBar: Bool

    // MARK: - History

    /// Days to keep rows in history.sqlite3. 1-day minimum, 30-day maximum.
    @Published var historyRetentionDays: Int

    // MARK: - Monitoring

    /// nettop sample interval in seconds (milestone 11). Applies to all
    /// nettop subprocesses; a shorter interval updates the UI more often at
    /// the cost of more nettop CPU. 1 / 2 / 5 s.
    @Published var refreshInterval: Int

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
    /// Show this month's accumulated total in the menu bar.
    @Published var showMonthInMenuBar: Bool

    private enum K {
        static let launchAtLogin              = "launchAtLogin"
        static let defaultSortModeRaw         = "defaultSortModeRaw"
        static let caseInsensitiveSearch      = "caseInsensitiveSearch"
        static let showDownloadInStatusBar    = "showDownloadInStatusBar"
        static let showUploadInStatusBar      = "showUploadInStatusBar"
        static let historyRetentionDays       = "historyRetentionDays"
        static let refreshInterval            = "refreshInterval"
        static let languageOverride           = "languageOverride"
        static let quotaEnabled               = "quotaEnabled"
        static let quotaPeriod                = "quotaPeriod"
        static let quotaLimitGB               = "quotaLimitGB"
        static let quotaCustomPercent         = "quotaCustomPercent"
        static let showTodayInMenuBar         = "showTodayInMenuBar"
        static let showMonthInMenuBar         = "showMonthInMenuBar"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read directly into backing storage; this bypasses the @Published
        // publishers' willChange and does not fire the `sink`s below.
        //
        // `launchAtLogin` is seeded from the *live* OS status (not from the
        // defaults value) because the macOS login-item state is the source of
        // truth: UserDefaults can drift when the user manages it in System
        // Settings (macOS 13+). Unsupported OSes (11–12) seed `false`.
        let launchStatus = LaunchAtLoginManager.currentStatus()
        self._launchAtLogin           = Published(initialValue: launchStatus == .enabled)
        self._defaultSortModeRaw      = Published(initialValue: defaults.string(forKey: K.defaultSortModeRaw) ?? "total")
        self._caseInsensitiveSearch   = Published(initialValue: defaults.object(forKey: K.caseInsensitiveSearch) as? Bool ?? true)
        self._showDownloadInStatusBar = Published(initialValue: defaults.object(forKey: K.showDownloadInStatusBar) as? Bool ?? true)
        self._showUploadInStatusBar   = Published(initialValue: defaults.object(forKey: K.showUploadInStatusBar) as? Bool ?? true)
        self._historyRetentionDays    = Published(initialValue: defaults.object(forKey: K.historyRetentionDays) as? Int ?? 7)
        self._refreshInterval         = Published(initialValue: defaults.object(forKey: K.refreshInterval) as? Int ?? 2)
        self._languageOverride        = Published(initialValue: defaults.string(forKey: K.languageOverride))
        self._quotaEnabled            = Published(initialValue: defaults.object(forKey: K.quotaEnabled) as? Bool ?? false)
        self._quotaPeriod             = Published(initialValue: defaults.string(forKey: K.quotaPeriod) ?? "month")
        self._quotaLimitGB            = Published(initialValue: defaults.object(forKey: K.quotaLimitGB) as? Int ?? 100)
        self._quotaCustomPercent      = Published(initialValue: defaults.object(forKey: K.quotaCustomPercent) as? Int ?? 0)
        self._showTodayInMenuBar      = Published(initialValue: defaults.object(forKey: K.showTodayInMenuBar) as? Bool ?? false)
        self._showMonthInMenuBar      = Published(initialValue: defaults.object(forKey: K.showMonthInMenuBar) as? Bool ?? false)

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
        $caseInsensitiveSearch.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.caseInsensitiveSearch) }
            .store(in: &cancellables)
        $showDownloadInStatusBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showDownloadInStatusBar) }
            .store(in: &cancellables)
        $showUploadInStatusBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showUploadInStatusBar) }
            .store(in: &cancellables)
        $historyRetentionDays.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.historyRetentionDays) }
            .store(in: &cancellables)
        $refreshInterval.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.refreshInterval) }
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
        $showMonthInMenuBar.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.showMonthInMenuBar) }
            .store(in: &cancellables)
    }
}
