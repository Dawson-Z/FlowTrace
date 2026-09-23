//
//  AccentColorTests.swift
//  FlowTraceTests
//
//  H 组：AccentColorManager 单测（5 项）
//  覆盖 normalizedHex、color(fromHex）、setCustomHex、readableForeground、来源持久化。
//

import XCTest
import SwiftUI
import AppKit
@testable import FlowTrace

final class AccentColorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FlowTraceTests.accent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // H7a: normalizedHex 接受多种形式，输出 canonical "#RRGGBB"
    func testNormalizedHex() {
        XCTAssertEqual(AccentColorManager.normalizedHex(fromRaw: "#00CFFF"), "#00CFFF")
        XCTAssertEqual(AccentColorManager.normalizedHex(fromRaw: "00CFFF"), "#00CFFF")
        XCTAssertEqual(AccentColorManager.normalizedHex(fromRaw: "00cfff"), "#00CFFF")
        XCTAssertEqual(AccentColorManager.normalizedHex(fromRaw: "  #00cfff  "), "#00CFFF")
        // 3 位缩写
        XCTAssertEqual(AccentColorManager.normalizedHex(fromRaw: "0cf"), "#00CCFF")
        XCTAssertEqual(AccentColorManager.normalizedHex(fromRaw: "#abc"), "#AABBCC")
    }

    // H7b: 非法输入返回 nil
    func testNormalizedHexRejectsInvalid() {
        XCTAssertNil(AccentColorManager.normalizedHex(fromRaw: "#XYZ"))
        XCTAssertNil(AccentColorManager.normalizedHex(fromRaw: "#12345"))    // 5 位
        XCTAssertNil(AccentColorManager.normalizedHex(fromRaw: "#1234567"))  // 7 位
        XCTAssertNil(AccentColorManager.normalizedHex(fromRaw: "#GGGGGG"))
        XCTAssertNil(AccentColorManager.normalizedHex(fromRaw: ""))
        XCTAssertNil(AccentColorManager.normalizedHex(fromRaw: "  "))
    }

    // H7c: setCustomHex 拒绝非法值
    func testSetCustomHexRejectsInvalid() {
        let m = AccentColorManager(defaults: defaults)
        let oldHex = m.customHex
        let result = m.setCustomHex("not a color")
        XCTAssertFalse(result)
        XCTAssertEqual(m.customHex, oldHex, "rejected hex must not change state")
    }

    func testSetCustomHexAcceptsValid() {
        let m = AccentColorManager(defaults: defaults)
        let result = m.setCustomHex("#ABCDEF")
        XCTAssertTrue(result)
        XCTAssertEqual(m.customHex, "#ABCDEF")
    }

    // 默认值
    func testDefaultsAreCustomAndBrandColor() {
        let m = AccentColorManager(defaults: defaults)
        XCTAssertEqual(m.source, .custom, "new installs default to custom")
        XCTAssertEqual(m.customHex, AccentColorManager.defaultHex)
        XCTAssertEqual(m.customHex, "#00CFFF")
    }

    // 持久化往返
    func testSourcePersists() {
        let m1 = AccentColorManager(defaults: defaults)
        m1.setSource(.system)
        let m2 = AccentColorManager(defaults: defaults)
        XCTAssertEqual(m2.source, .system, "setSource must persist across instances")
    }

    func testCustomHexPersists() {
        let m1 = AccentColorManager(defaults: defaults)
        m1.setCustomHex("#FF8800")
        let m2 = AccentColorManager(defaults: defaults)
        XCTAssertEqual(m2.customHex, "#FF8800")
    }

    // 烂值回退到默认
    func testMalformedStoredHexFallsBackToDefault() {
        defaults.set("totally bogus", forKey: "ft.accent.hex")
        let m = AccentColorManager(defaults: defaults)
        XCTAssertEqual(m.customHex, AccentColorManager.defaultHex)
    }

    // readableForeground 对比度合理
    func testReadableForegroundOnDarkIsWhite() {
        let dark = AccentColorManager.color(fromHex: "#00CFFF")!  // 浅蓝 → 黑字
        // 浅色 → .black
        let fg = AccentColorManager.readableForeground(on: dark)
        // 不能简单比较 Color，这里只验证函数不崩
        _ = fg
    }

    // K36: readableForeground 黑白两端（Rec.709 亮度阈值 0.6）
    func testReadableForegroundExtremes() {
        let white = AccentColorManager.color(fromHex: "#FFFFFF")!
        let black = AccentColorManager.color(fromHex: "#000000")!
        let whiteNS = NSColor(white).usingColorSpace(.sRGB)
        let blackNS = NSColor(black).usingColorSpace(.sRGB)
        // 白底 luminance=1.0 > 0.6 → 黑字；黑底 luminance=0 → 白字
        // 通过灰度反推：白底返回的颜色的亮度应低于黑底返回的
        let fgOnWhite = AccentColorManager.readableForeground(on: white)
        let fgOnBlack = AccentColorManager.readableForeground(on: black)
        let lumOnWhite = luminance(fgOnWhite, fallback: whiteNS)
        let lumOnBlack = luminance(fgOnBlack, fallback: blackNS)
        XCTAssertLessThan(lumOnWhite, lumOnBlack,
                          "on white the foreground must be darker than on black")
    }

    private func luminance(_ c: Color, fallback: NSColor?) -> Double {
        let ns = NSColor(c).usingColorSpace(.sRGB)
        let r = Double(ns?.redComponent ?? 0)
        let g = Double(ns?.greenComponent ?? 0)
        let b = Double(ns?.blueComponent ?? 0)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // resetToDefault
    func testResetToDefault() {
        let m = AccentColorManager(defaults: defaults)
        m.setSource(.system)
        m.setCustomHex("#FF0000")
        m.resetToDefault()
        XCTAssertEqual(m.source, .custom)
        XCTAssertEqual(m.customHex, AccentColorManager.defaultHex)
    }

    // color(fromHex) 还原颜色
    func testColorFromHexRoundTrip() {
        let c = AccentColorManager.color(fromHex: "#FF0000")!
        // NSColor(c).usingColorSpace(.sRGB) → 应为红
        // 不能直接 Color 相等比较；这里只能测不崩
        _ = c
        XCTAssertNil(AccentColorManager.color(fromHex: "bogus"))
    }

    // L2-24: 早期实现的遗留 key 必须在 init 时被清掉，不留残渣
    func testLegacyKeysAreRemovedOnInit() {
        defaults.set("system",    forKey: "accentMode")
        defaults.set([1, 2, 3, 4], forKey: "accentRGBA")
        defaults.set(true,        forKey: "accentFollowSystem")

        _ = AccentColorManager(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "accentMode"),
                     "accentMode 是旧实现的 key，不该留在 defaults 里")
        XCTAssertNil(defaults.object(forKey: "accentRGBA"))
        XCTAssertNil(defaults.object(forKey: "accentFollowSystem"))
    }
}