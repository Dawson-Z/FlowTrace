//
//  LocalizationManager.swift
//  FlowTrace — Feature/Localization
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

    /// The app's own name, in the language the user picked: 流探 for Chinese
    /// (the value in that locale's `InfoPlist.strings`, which is also what
    /// Finder and the menu bar show) and the product name for every other
    /// language. Used by the popover header and the About pane, so the two
    /// cannot disagree about what the app is called.
    ///
    /// The locale is checked *first* on purpose: `l(_:)` falls back to the
    /// main bundle when a table misses, and the main bundle resolves the
    /// *system* language — so on a Chinese system an English override would
    /// still have read 流探.
    static var appDisplayName: String {
        guard manager.locale.hasPrefix("zh") else { return "FlowTrace" }
        let name = l("CFBundleDisplayName", "InfoPlist")
        return name == "CFBundleDisplayName" ? "FlowTrace" : name
    }

    /// A date formatter bound to the app's current language, built from a
    /// **localized template** rather than a fixed pattern — so the field order,
    /// the separators and the 12/24-hour choice all follow the locale instead
    /// of the system's.
    ///
    /// Use this for anything a person reads. Machine-facing timestamps keep
    /// their fixed ISO patterns on purpose: `CSVExporter` so the exported file
    /// sorts and parses anywhere, and `DataRetentionController.dayKey` because
    /// it is a dedup key rather than a label.
    ///
    /// Call sites must not cache the result in a `static let`: the language can
    /// change at runtime, and a cached formatter would keep the old one.
    static func dateFormatter(template: String, locale: String? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale ?? manager.locale)
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
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

        // React to explicit overrides from the Settings window.
        //
        // We deliberately do NOT use `.removeDuplicates()` here. The
        // ObservedObject plumbing in `SettingsPane` and `SettingsTabBar`
        // re-renders on every publisher tick, so any duplicate the picker
        // produces (or a no-op edit) would still cost nothing — but using
        // `removeDuplicates` is what produced the "second language change
        // does nothing" bug: the manager fires `locale = ...` on every
        // override change, and if two consecutive changes resolve to the same
        // `locale` string (e.g. follow-system → zh-Hans → follow-system on a
        // Chinese system both resolve to zh-Hans), `removeDuplicates`
        // suppresses the second `$locale` emission. The panes therefore only
        // re-render on changes where the resolved locale differs from the
        // previous resolved locale, which is precisely "the second change
        // looks stuck".
        //
        // Drop the duplicate suppression; the manager is the source of
        // truth, and any churn is harmless because no view listens to
        // changes that do not affect strings.
        SettingsStore.shared.$languageOverride
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

    /// Locales shipped with the app (each has an .lproj folder).
    ///
    /// Internal rather than private so `LocalizationTests` can assert that
    /// every one of them is actually findable in the built bundle: a locale
    /// that is listed here but missing from the bundle degrades to the *system*
    /// language with nothing but a log line to show for it.
    static let supportedLocales: Set<String> = [
        "en", "zh-Hans", "zh-Hant", "es", "pt-BR", "fr", "de", "it", "ru",
        "ja", "ko", "vi", "hi", "bn", "ur", "pa", "mr", "ta", "jv", "ar", "fa",
    ]

    /// Best-effort detection of the user's preferred system language.
    /// AppleLanguages entries usually carry a region tag ("es-US"), so first
    /// try an exact case-insensitive hit, then fall back to the language
    /// subtag ("es-US" → "es") so follow-system finds the right .lproj.
    static func systemLocale() -> String {
        let prefs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] ?? ["en"]
        for pref in prefs {
            let lower = pref.lowercased()
            if let exact = supportedLocales.first(where: { $0.lowercased() == lower }) {
                return exact
            }
            let subtag = lower.split(separator: "-").first.map(String.init) ?? ""
            if !subtag.isEmpty,
               let hit = supportedLocales.first(where: { $0.lowercased().hasPrefix(subtag) }) {
                return hit
            }
        }
        return "en"
    }

    private func reloadBundle() {
        // Locate the .lproj for the current locale inside the app bundle;
        // fall back to the main bundle (Base / en) so a missing locale never
        // renders a raw key.
        if let bundle = Self.lprojBundle(for: locale, in: .main) {
            languageBundle = bundle
            Log.l10n.info("bundle loaded for \(self.locale)")
        } else {
            languageBundle = .main
            Log.l10n.error("lproj missing for \(self.locale); falling back to main bundle at \(Bundle.main.bundlePath)")
        }
    }

    /// The `.lproj` Bundle for `locale` inside `bundle`, or nil when the app
    /// was not built with that localization.
    ///
    /// Two lookups on purpose. `path(forResource:ofType:)` is the documented
    /// way to find a localization, but it answers from the bundle's
    /// localisation *state* rather than from what is on disk, and it can miss
    /// a folder that is really there — the development region is the usual
    /// suspect. The previous single-lookup version then fell straight through
    /// to the main bundle, whose strings resolve to the **system** language,
    /// so an English override on a Chinese system silently rendered Chinese
    /// instead of failing loudly. The second lookup asks the file system the
    /// plain question ("is that folder there?") and cannot miss.
    static func lprojBundle(for locale: String, in bundle: Bundle) -> Bundle? {
        if let path = bundle.path(forResource: locale, ofType: "lproj"),
           let found = Bundle(path: path) {
            return found
        }
        guard let url = bundle.resourceURL?.appendingPathComponent("\(locale).lproj"),
              FileManager.default.fileExists(atPath: url.path),
              let found = Bundle(url: url) else { return nil }
        return found
    }

    /// Sentinel that can never collide with a real translation, so we can
    /// tell "key found" from "key missing" — `value != key` does NOT work:
    /// every English value equals its key ("Settings" = "Settings"), which
    /// made the English locale always fall through to the main bundle
    /// (i.e. the system language).
    private static let missingMarker = "__FlowTrace_missing__"

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
