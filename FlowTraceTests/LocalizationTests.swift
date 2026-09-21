//
//  LocalizationTests.swift
//  FlowTraceTests
//
//  The runtime language override reads its strings from the chosen locale's
//  `.lproj` bundle. When that bundle cannot be located, `LocalizationManager`
//  falls back to the main bundle — whose strings resolve to the **system**
//  language — so an English override on a Chinese system silently keeps
//  rendering Chinese. Nothing in the UI reports that, which is exactly why it
//  needs a test.
//

import XCTest
@testable import FlowTrace

final class LocalizationTests: XCTestCase {

    /// The app bundle. `Bundle.main` is the host app under `TEST_HOST`, but
    /// `Bundle(for:)` stays correct if the test host ever changes.
    private var appBundle: Bundle { Bundle(for: ListViewModel.self) }

    // MARK: - Every shipped locale is present and readable

    func testEverySupportedLocaleHasItsLprojOnDisk() {
        for locale in LocalizationManager.supportedLocales.sorted() {
            let dir = appBundle.resourceURL?.appendingPathComponent("\(locale).lproj")
            XCTAssertNotNil(dir, "no resource directory for \(locale)")
            XCTAssertTrue(dir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                          "\(locale).lproj is missing from the built bundle")
        }
    }

    func testEverySupportedLocaleResolvesAKnownKey() {
        for locale in LocalizationManager.supportedLocales.sorted() {
            let bundle = LocalizationManager.lprojBundle(for: locale, in: appBundle)
            XCTAssertNotNil(bundle, "\(locale).lproj could not be opened")

            let value = bundle?.localizedString(forKey: "Settings",
                                                value: "__missing__",
                                                table: "Localizable")
            XCTAssertNotEqual(value, "__missing__",
                              "\(locale) has no translation for the Settings key")
        }
    }

    /// The lookup the runtime actually performs, against `Bundle.main`. This is
    /// the one that regressed: `path(forResource:ofType:)` is not guaranteed to
    /// find a `.lproj` that is present on disk.
    func testMainBundleLookupReachesEverySupportedLocale() {
        for locale in LocalizationManager.supportedLocales.sorted() {
            XCTAssertNotNil(Bundle.main.path(forResource: locale, ofType: "lproj"),
                            "Bundle.main could not locate \(locale).lproj")
        }
    }

    /// Guards the fallback itself: even where `path(forResource:ofType:)`
    /// comes back empty, the locale must still be reachable.
    func testLprojLookupDoesNotDependOnPathForResourceOfType() {
        for locale in LocalizationManager.supportedLocales.sorted() {
            XCTAssertNotNil(LocalizationManager.lprojBundle(for: locale, in: appBundle),
                            "\(locale) is unreachable through lprojBundle(for:in:)")
        }
    }

    func testEnglishAndChineseDoNotResolveTheSameTable() throws {
        let english = try XCTUnwrap(LocalizationManager.lprojBundle(for: "en", in: appBundle))
        let chinese = try XCTUnwrap(LocalizationManager.lprojBundle(for: "zh-Hans", in: appBundle))

        let englishValue = english.localizedString(forKey: "Settings", value: "__missing__",
                                                   table: "Localizable")
        let chineseValue = chinese.localizedString(forKey: "Settings", value: "__missing__",
                                                   table: "Localizable")

        XCTAssertNotEqual(englishValue, "__missing__")
        XCTAssertNotEqual(chineseValue, "__missing__")
        XCTAssertNotEqual(englishValue, chineseValue,
                          "both locales resolved to the same table — the override is not reading the chosen .lproj")
    }

    // MARK: - Locale resolution

    func testExplicitOverrideWins() {
        XCTAssertEqual(LocalizationManager.resolveLocale(override: "fr"), "fr")
        XCTAssertEqual(LocalizationManager.resolveLocale(override: "zh-Hant"), "zh-Hant")
    }

    func testEmptyOverrideFallsBackToTheSystemLanguage() {
        let resolved = LocalizationManager.resolveLocale(override: "")
        XCTAssertTrue(LocalizationManager.supportedLocales.contains(resolved),
                      "resolved to \(resolved), which the app does not ship")
    }

    func testFollowSystemAlwaysResolvesToAShippedLocale() {
        let resolved = LocalizationManager.resolveLocale(override: nil)
        XCTAssertTrue(LocalizationManager.supportedLocales.contains(resolved),
                      "resolved to \(resolved), which the app does not ship")
    }

    // MARK: - Localized date formatting

    private let sampleDate = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 20, hour: 12)
    )!

    func testDateFormatterFollowsTheRequestedLanguage() {
        let english = Loc.dateFormatter(template: "yMd", locale: "en").string(from: sampleDate)
        let german = Loc.dateFormatter(template: "yMd", locale: "de").string(from: sampleDate)

        XCTAssertNotEqual(english, german,
                          "the formatter must follow the requested language, not the system's")
        XCTAssertTrue(english.contains("/"), "en separates with slashes: \(english)")
        XCTAssertTrue(german.contains("."), "de separates with dots: \(german)")
    }

    /// Proof that it is a *template*: the same one produces a different field
    /// order per language, which a fixed pattern could not do.
    func testDateFormatterUsesATemplateNotAFixedPattern() {
        let english = Loc.dateFormatter(template: "yMd", locale: "en").string(from: sampleDate)
        let chinese = Loc.dateFormatter(template: "yMd", locale: "zh-Hans").string(from: sampleDate)

        XCTAssertTrue(english.hasPrefix("9/"), "en leads with the month: \(english)")
        XCTAssertTrue(chinese.hasPrefix("2026"), "zh-Hans leads with the year: \(chinese)")
    }

    func testDateFormatterPicksTheLanguagesHourCycle() {
        // Region-qualified on purpose: a bare "en" does not pin the hour cycle
        // (en_GB is 24-hour), and this test is about `j` following the locale
        // rather than a hard-coded 12 or 24.
        let english = Loc.dateFormatter(template: "jm", locale: "en-US").string(from: sampleDate)
        let chinese = Loc.dateFormatter(template: "jm", locale: "zh-CN").string(from: sampleDate)

        XCTAssertTrue(english.contains("PM") || english.contains("AM"),
                      "en-US uses a 12-hour clock: \(english)")
        XCTAssertFalse(chinese.contains("PM") || chinese.contains("AM"),
                       "zh-CN uses a 24-hour clock: \(chinese)")
    }

    func testEverySupportedLocaleFormatsADateNonEmpty() {
        for locale in LocalizationManager.supportedLocales.sorted() {
            let text = Loc.dateFormatter(template: "yMd", locale: locale).string(from: sampleDate)
            XCTAssertFalse(text.isEmpty, "\(locale) produced an empty date")
            XCTAssertGreaterThan(text.count, 4, "\(locale) produced a suspicious date: \(text)")
        }
    }

    /// The order trap: `setLocalizedDateFormatFromTemplate` resolves the
    /// template **immediately**, against whatever locale the formatter has at
    /// that moment. Calling it before setting `.locale` therefore bakes in the
    /// system's pattern — which is how the month title ended up rendering
    /// "2026年9月" in every language on a Chinese system.
    func testMonthTitleTemplateExpandsWithTheRequestedLocale() {
        let english = Loc.dateFormatter(template: "yMMMM", locale: "en").string(from: sampleDate)

        XCTAssertEqual(english, "September 2026")
        XCTAssertFalse(english.contains("年"),
                       "the system's pattern leaked into the English month title: \(english)")
    }

    func testMonthTitleDiffersPerLanguage() {
        let english = Loc.dateFormatter(template: "yMMMM", locale: "en").string(from: sampleDate)
        let chinese = Loc.dateFormatter(template: "yMMMM", locale: "zh-Hans").string(from: sampleDate)

        XCTAssertEqual(chinese, "2026年9月")
        XCTAssertNotEqual(english, chinese)
    }
}
