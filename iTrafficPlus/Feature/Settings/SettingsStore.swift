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

    private enum K {
        static let launchAtLogin              = "launchAtLogin"
        static let defaultSortModeRaw         = "defaultSortModeRaw"
        static let caseInsensitiveSearch      = "caseInsensitiveSearch"
        static let showDownloadInStatusBar    = "showDownloadInStatusBar"
        static let showUploadInStatusBar      = "showUploadInStatusBar"
        static let historyRetentionDays       = "historyRetentionDays"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read directly into backing storage; this bypasses the @Published
        // publishers' willChange and does not fire the `sink`s below.
        self._launchAtLogin           = Published(initialValue: defaults.bool(forKey: K.launchAtLogin))
        self._defaultSortModeRaw      = Published(initialValue: defaults.string(forKey: K.defaultSortModeRaw) ?? "total")
        self._caseInsensitiveSearch   = Published(initialValue: defaults.object(forKey: K.caseInsensitiveSearch) as? Bool ?? true)
        self._showDownloadInStatusBar = Published(initialValue: defaults.object(forKey: K.showDownloadInStatusBar) as? Bool ?? true)
        self._showUploadInStatusBar   = Published(initialValue: defaults.object(forKey: K.showUploadInStatusBar) as? Bool ?? true)
        self._historyRetentionDays    = Published(initialValue: defaults.object(forKey: K.historyRetentionDays) as? Int ?? 7)

        // Each sink starts with the just-loaded value; `.dropFirst()` skips
        // that initial replay, so only real user edits round-trip to disk.
        $launchAtLogin.dropFirst()
            .sink { [weak self] v in self?.defaults.set(v, forKey: K.launchAtLogin) }
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
    }
}
