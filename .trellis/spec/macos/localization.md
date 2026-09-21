//
//  macOS / localization.md
//  FlowTrace — Trellis spec
//
//  The runtime-language rules this codebase actually follows.
//  Anchored on real file paths and the bugs that produced them.
//

# Localization

## The helpers

```swift
// FlowTrace/Feature/Localization/LocalizationManager.swift
enum Loc {
    static func l(_ key: String, _ table: String = "Localizable") -> String
    static var appDisplayName: String
    static func dateFormatter(template: String, locale: String? = nil) -> DateFormatter
}
```

- `Loc.l(_:)` — every user-visible literal string. Reads from the
  bundle selected by `LocalizationManager.shared.locale`.
- `Loc.appDisplayName` — `CFBundleDisplayName` from the matching
  `.lproj` (Chinese name on Chinese systems, product name elsewhere).
- `Loc.dateFormatter(template:locale:)` — see "Date formatting"
  below.

If you are reaching for a `Text("literal")` anywhere, you are
probably wrong: that string is resolved against `Bundle.main` and
will not follow an in-app language override.

## Why `bundle.localizedString` needs a sentinel

```swift
// FlowTrace/Feature/Localization/LocalizationManager.swift
private static let missingMarker = "__FlowTrace_missing__"

func string(_ key: String, table: String = "Localizable") -> String {
    if let bundle = languageBundle {
        let value = bundle.localizedString(forKey: key,
                                            value: Self.missingMarker,
                                            table: table)
        if value != Self.missingMarker { return value }
    }
    // fall back to main bundle…
}
```

`value != key` does **not** detect a missing key when the English
value equals the key (which is the case for many strings in this
app — "Settings" → "Settings"). The sentinel has to be something
no real translation can ever equal.

If you add a new call site that needs this behaviour, reach for
the same pattern via `Loc.l(_:)`. Do not write your own.

## "Follow system" vs explicit override

- `LocalizationManager.shared.locale` is the single source of truth.
- A user setting (`languageOverride`) in `UserDefaults` either:
  - contains a locale string from `LocalizationManager.supportedLocales` → that locale is used, OR
  - is empty / missing → the system language is matched against
    `supportedLocales` (case-insensitive, with a sub-tag fallback
    so `"es-US"` matches `"es"`).
- The resolved locale string is **never `nil`** — it always lands
  on a shipped locale, with `"en"` as the final fallback.

If a feature module listens to `$languageOverride`, sink on it
**without** `.removeDuplicates()`. See `combine-pitfalls.md` §4.

## Date formatting

Use `Loc.dateFormatter(template:locale:)` for anything a person
reads. Use a `static let` `DateFormatter` with a fixed pattern only
for machine-facing timestamps.

| Site | Format | Why |
| --- | --- | --- |
| Field label inside `AccentDateField` | `.short` / `.medium` style | Width-bounded by the 130 pt control. |
| Heatmap grid date label | `Md` template | Locale decides field order. |
| Heatmap hover footer | `Md` + `Hm` | Locale decides separators and hour cycle. |
| Alert log time column | `yMdjms` template | Locale decides hour cycle and date order. |
| Settings storage "clear range" | `yMd` template | Same. |
| **CSV export** | `yyyy-MM-dd HH:mm:ss` | **Machine-facing**, keep fixed so spreadsheets parse anywhere. |
| **Retention dedup key** (`DataRetentionController.dayKey`) | `yyyy-MM-dd` | **Machine-facing**, keep fixed. |

### The order trap

`setLocalizedDateFormatFromTemplate` resolves the template
**immediately**, against whatever locale the formatter holds at
that moment. Setting `.locale` afterwards cannot change a pattern
that is already resolved. This is how the month title came to
render "2026年9月" in every language on a Chinese system.

`Loc.dateFormatter` sets the locale *first*, then expands. Use it.
If a hand-rolled formatter is unavoidable (e.g. it needs
`dateStyle`), put the locale assignment before the style assignment
for consistency.

### Cached formatters are dangerous

`Loc.dateFormatter` builds a fresh formatter each call. That is
intentional — the language can change at runtime, and a `static
let` formatter would keep the previous one. If you need the
performance of a cached formatter, cache by locale and rebuild on
locale change. Do not use a single cached formatter as a `static let`.

## `\.appDisplayName` is read *first*, before any string table miss

`Loc.appDisplayName` exists because the popover header and the
Settings → About pane must agree on what the app is called. Both
places read the locale-aware name. If a locale's `InfoPlist.strings`
is missing `CFBundleDisplayName`, the helper falls back to
`"FlowTrace"` (the product name) rather than to the main bundle —
because the main bundle resolves to the system language, and on
a Chinese system an English override would otherwise show
流探.

## Supported locales

`LocalizationManager.supportedLocales` is the canonical list (21
locales). Adding a new language requires:

1. `FlowTraceForMac/<new>.lproj/Localizable.strings`.
2. The locale string in `LocalizationManager.supportedLocales`.
3. An explicit `path: <new>.lproj` entry under
   `resources:` in `project.yml`.
4. Optionally `FlowTraceForMac/<new>.lproj/InfoPlist.strings`
   if the locale has a translated app display name.
5. A test entry in `LocalizationTests.swift`.

There are tests that pin every locale must (a) exist on disk,
(b) open as a `Bundle`, and (c) resolve at least one known key —
see `LocalizationTests.swift`. They will fail loudly if any of the
above is missing.

## What is and is not localized

Localized:
- Strings in any `Localizable.strings` table, looked up via `Loc.l`.
- Weekday names (via `AccentDateField.weekdayHeadings(for:)`).
- Date format and order (via `Loc.dateFormatter`).
- Month title (via `Loc.dateFormatter(template: "yMMMM")`).

NOT localized (deliberate):
- CSV file timestamps (`CSVExporter`).
- Retention checkpoint dedup key (`DataRetentionController.dayKey`).
- Strings that look like keys but are actually values — for
  example, the placeholder name in some empty-state views.
- Log lines under `~/Library/Logs/FlowTrace.log` — these are for
  debugging, not user-visible.