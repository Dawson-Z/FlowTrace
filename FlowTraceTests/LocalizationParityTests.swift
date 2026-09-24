//
//  LocalizationParityTests.swift
//  FlowTraceTests
//
//  A strict structural guarantee for the 21 Localizable.strings tables:
//  every table must expose the exact same key set. The size-based probes
//  in LocalizationResourceTests catch gross truncation, but a language
//  missing one newly added key (or carrying a stale extra one) used to
//  slide through — this test fails with a precise per-locale diff.
//

import XCTest
@testable import FlowTrace

final class LocalizationParityTests: XCTestCase {

    func testAllLocaleTablesExposeTheSameKeySet() throws {
        let appBundle = Bundle(for: ListViewModel.self)
        var reference: (locale: String, keys: Set<String>)?

        for locale in LocalizationManager.supportedLocales.sorted() {
            let bundle = try XCTUnwrap(LocalizationManager.lprojBundle(for: locale, in: appBundle),
                                       "\(locale).lproj 无法打开")
            let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings"),
                                     "\(locale) 缺少 Localizable.strings")
            let dictionary = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String],
                                           "\(locale) 的 Localizable.strings 无法解析")
            let keys = Set(dictionary.keys)
            guard let reference else {
                reference = (locale, keys)
                continue
            }
            let missing = reference.keys.subtracting(keys)
            let extra = keys.subtracting(reference.keys)
            XCTAssertTrue(missing.isEmpty && extra.isEmpty,
                          "\(locale) 与 \(reference.locale) 的 key 集合不一致；"
                          + "缺少 \(missing.sorted())，多出 \(extra.sorted())")
        }
        XCTAssertNotNil(reference, "at least one table must have been read")
        XCTAssertGreaterThan(reference?.keys.count ?? 0, 100, "tables should hold the full key set")
    }
}
