//
//  LocalizationResourceTests.swift
//  FlowTraceTests
//
//  L2-20 ~ L2-22：本地化**资源表**的全量加载与回退。
//  上轮只抽样断言了 "Settings" 一个 key，未覆盖「21 张表都能独立解析」「缺 key 回退」
//  「InfoPlist 表只随中文包发布」这三件事。
//

import XCTest
@testable import FlowTrace

final class LocalizationResourceTests: XCTestCase {

    private var appBundle: Bundle { Bundle(for: ListViewModel.self) }

    private let sentinel = "__FlowTrace_missing__"

    // MARK: - L2-20  21 张表逐一加载

    func testEveryLocaleHasNonEmptySettingsString() throws {
        var translations: [String: String] = [:]

        for locale in LocalizationManager.supportedLocales.sorted() {
            let bundle = try XCTUnwrap(LocalizationManager.lprojBundle(for: locale, in: appBundle),
                                       "\(locale).lproj 无法打开")
            let value = bundle.localizedString(forKey: "Settings", value: sentinel, table: "Localizable")
            XCTAssertNotEqual(value, sentinel, "\(locale) 缺少 Settings")
            XCTAssertFalse(value.isEmpty, "\(locale) 的 Settings 是空串")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(locale) 的 Settings 只有空白")
            translations[locale] = value
        }

        XCTAssertEqual(translations.count, 21, "应覆盖 21 个语言")

        // 防「所有语言都落到同一张表」：译文必须有相当数量的互异值
        let distinct = Set(translations.values)
        XCTAssertGreaterThanOrEqual(distinct.count, 12,
                                    "21 个语言只产出 \(distinct.count) 种译文，疑似多语言回退到同一张表")

        // 中英必须不同（回归：旧实现会把 en 也解析到系统语言）
        XCTAssertNotEqual(translations["en"], translations["zh-Hans"])
    }

    /// 每张表都应有相当规模——防「表存在但只有 1~2 条」的残缺包。
    func testEveryLocaleTableHasReasonableSize() throws {
        for locale in LocalizationManager.supportedLocales.sorted() {
            let bundle = try XCTUnwrap(LocalizationManager.lprojBundle(for: locale, in: appBundle))
            // 逐个抽查若干真实存在于英文包里的 key
            let probes = ["Settings", "History", "Today", "Name", "Clear data"]
            var hits = 0
            for key in probes {
                let v = bundle.localizedString(forKey: key, value: sentinel, table: "Localizable")
                if v != sentinel { hits += 1 }
            }
            XCTAssertGreaterThanOrEqual(hits, 4,
                                        "\(locale) 只命中 \(hits)/\(probes.count) 个探针 key，疑似残缺的字符串表")
        }
    }

    // MARK: - L2-21  缺 key 的回退链

    func testMissingKeyFallsBackToTheKeyItself() {
        // 三个层次都查不到时，必须返回 key 本身（而不是空串），让缺陷可见
        let missing = "__flowtrace_definitely_missing_key__"
        XCTAssertEqual(LocalizationManager.shared.string(missing), missing)
        XCTAssertEqual(Loc.l(missing), missing)
    }

    func testExistingKeyIsNotEchoedBack() {
        // 已存在的 key 必须拿到真译文，而不是原样回显
        let value = LocalizationManager.shared.string("Settings")
        XCTAssertNotEqual(value, "Settings", "Settings 在各语言中都有译文，不应回显 key")
    }

    // MARK: - L2-22  InfoPlist 表只随中文包发布

    func testInfoPlistDisplayNameExistsOnlyForChineseBundles() throws {
        for locale in ["zh-Hans", "zh-Hant"] {
            let bundle = try XCTUnwrap(LocalizationManager.lprojBundle(for: locale, in: appBundle))
            let name = bundle.localizedString(forKey: "CFBundleDisplayName",
                                              value: sentinel, table: "InfoPlist")
            XCTAssertNotEqual(name, sentinel,
                              "\(locale) 必须带 InfoPlist 的 CFBundleDisplayName（菜单栏/关于页用它显示 流探）")
            XCTAssertFalse(name.isEmpty)
        }

        // 英文包不带 InfoPlist.strings，因此取不到（这不是缺陷，是设计）
        let en = try XCTUnwrap(LocalizationManager.lprojBundle(for: "en", in: appBundle))
        let enName = en.localizedString(forKey: "CFBundleDisplayName",
                                       value: sentinel, table: "InfoPlist")
        XCTAssertEqual(enName, sentinel, "英文包不应提供 InfoPlist 表（appDisplayName 会回落到 FlowTrace）")
    }

    func testAppDisplayNameIsNeverEmpty() {
        XCTAssertFalse(Loc.appDisplayName.isEmpty)
    }
}
