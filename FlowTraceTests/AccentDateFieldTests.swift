//
//  AccentDateFieldTests.swift
//  FlowTraceTests
//
//  The month-grid date field is hand-built (see AGENTS.md on the accent
//  controls), so its localisation is ours to get right rather than the
//  platform's.
//
//  The bug this pins: the weekday headings were read from
//  `Calendar.current.veryShortWeekdaySymbols`, and `Calendar.current`'s locale
//  is the **system's**. So an English override on a Chinese system still drew
//  日 一 二 三 四 五 六 above the grid, while every other string in the window
//  followed the in-app language.
//

import XCTest
@testable import FlowTrace

final class AccentDateFieldTests: XCTestCase {

    func testWeekdayHeadingsFollowTheRequestedLocale() {
        let english = AccentDateField.weekdayHeadings(for: "en")
        let chinese = AccentDateField.weekdayHeadings(for: "zh-Hans")

        XCTAssertEqual(english.count, 7)
        XCTAssertEqual(chinese.count, 7)
        XCTAssertTrue(english.contains("S"), "expected English headings, got \(english)")
        XCTAssertTrue(chinese.contains("日"), "expected Chinese headings, got \(chinese)")
        XCTAssertNotEqual(english, chinese,
                          "the headings must depend on the requested locale, not the system's")
    }

    /// The regression itself. This machine runs a Chinese system locale, so a
    /// naive `Calendar.current.veryShortWeekdaySymbols` returns Chinese here.
    func testEnglishHeadingsDoNotFallBackToTheSystemLanguage() {
        XCTAssertEqual(AccentDateField.weekdayHeadings(for: "en"),
                       ["S", "M", "T", "W", "T", "F", "S"])
    }

    /// `de` starts the week on Monday, so the first column is Montag.
    func testHeadingsStartOnTheLocaleFirstWeekday() {
        XCTAssertEqual(AccentDateField.weekdayHeadings(for: "de").first, "M")
        XCTAssertEqual(AccentDateField.weekdayHeadings(for: "en").first, "S")
    }

    func testEverySupportedLocaleProducesSevenNonEmptyHeadings() {
        for locale in LocalizationManager.supportedLocales.sorted() {
            let headings = AccentDateField.weekdayHeadings(for: locale)
            XCTAssertEqual(headings.count, 7, "\(locale) produced \(headings)")
            XCTAssertFalse(headings.contains { $0.isEmpty },
                           "\(locale) produced an empty heading: \(headings)")
        }
    }

    /// The rotation must be a pure reordering — no symbol lost, none invented —
    /// because the heading order and the column the 1st of the month lands in
    /// are computed from the same `firstWeekday`.
    func testHeadingsAreARotationOfTheLocaleSymbols() {
        for locale in ["en", "de", "ar", "fa", "zh-Hans"] {
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: locale)
            XCTAssertEqual(Set(AccentDateField.weekdayHeadings(for: locale)),
                           Set(calendar.veryShortWeekdaySymbols),
                           "\(locale): headings are not a rotation of its weekday symbols")
        }
    }
}
