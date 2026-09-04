//
//  LocalizationManager.swift
//  iTrafficPlus — Feature/Localization
//
//  Runtime language selector. Supports "follow the system" (the default)
//  plus a manual override stored in Settings. Because SwiftUI's `Text("key")`
//  automatic localisation always consults the *main* bundle's resolved
//  language, a runtime override needs its own lookup path: we locate the
//  `.lproj` Bundle for the chosen locale and read strings from it, and every
//  user-visible string in the app goes through the single `Loc.l(_:)` helper.
//
//  Deployment target is 11.0, so `NSLocalizedString` + `Bundle(path:lproj)`
//  is the right tool — no macOS 13-only localization APIs.
//

import Foundation
import Combine

/// Typed convenience accessor used across views.
enum Loc {
    static let manager = LocalizationManager.shared
    static func l(_ key: String, _ table: String = "Localizable") -> String {
        manager.string(key, table: table)
    }
}

final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    /// The language currently in effect (e.g. "en", "zh-Hans", "zh-Hant").
    /// Published so views observing `shared` repaint when an override changes.
    @Published private(set) var locale: String

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var languageBundle: Bundle?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.locale = Self.resolveLocale(override: defaults.string(forKey: Self.overrideKey))
        self.reloadBundle()
        Log.l10n.info("init: override=\(defaults.string(forKey: Self.overrideKey) ?? "nil"), locale=\(self.locale)")

        // React to explicit overrides from the Settings window. `.removeDuplicates`
        // skips the initial replay (the value is already applied in `init`).
        SettingsStore.shared.$languageOverride
            .removeDuplicates()
            .sink { [weak self] new in
                guard let self else { return }
                Log.l10n.info("override changed to \(new ?? "nil")")
                self.locale = Self.resolveLocale(override: new)
                self.reloadBundle()
            }
            .store(in: &cancellables)
    }

    private static let overrideKey = "languageOverride"

    /// `nil` = follow the system. Returns the resolved locale string.
    static func resolveLocale(override: String?) -> String {
        if let override, !override.isEmpty { return override }
        return systemLocale()
    }

    /// Best-effort detection of the user's preferred system language.
    static func systemLocale() -> String {
        let prefs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] ?? ["en"]
        let first = prefs.first?.lowercased() ?? "en"
        if first.hasPrefix("zh-hant") { return "zh-Hant" }
        if first.hasPrefix("zh")      { return "zh-Hans" }
        if first.hasPrefix("en")      { return "en" }
        return prefs.first ?? "en"
    }

    private func reloadBundle() {
        // Locate the .lproj for the current locale inside the app bundle;
        // fall back to the main bundle (Base / en) so a missing locale never
        // renders a raw key.
        if let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            languageBundle = bundle
            Log.l10n.info("bundle loaded for \(self.locale)")
        } else {
            languageBundle = .main
            Log.l10n.error("lproj missing for \(self.locale); falling back to main bundle")
        }
    }

    /// Sentinel that can never collide with a real translation, so we can
    /// tell "key found" from "key missing" — `value != key` does NOT work:
    /// every English value equals its key ("Settings" = "Settings"), which
    /// made the English locale always fall through to the main bundle
    /// (i.e. the system language).
    private static let missingMarker = "__iTrafficPlus_missing__"

    func string(_ key: String, table: String = "Localizable") -> String {
        if let bundle = languageBundle {
            let value = bundle.localizedString(forKey: key, value: Self.missingMarker, table: table)
            if value != Self.missingMarker { return value }
        }
        // Key missing in the selected locale's table: fall back to the main
        // bundle (Base / en). If it is missing everywhere, show the key so
        // the bug is visible rather than rendering an empty string.
        let fallback = Bundle.main.localizedString(forKey: key, value: Self.missingMarker, table: table)
        return fallback != Self.missingMarker ? fallback : key
    }
}
