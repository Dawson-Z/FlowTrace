//
//  InterfaceClassifierTests.swift
//  FlowTraceTests
//
//  F 组：InterfaceClassifier 纯函数测试。
//
//  历史：本轮之前这里有 5 个「bug 暴露」用例（用 `XCTAssertNotEqual(.other)` 记录
//  源码的错误行为）。三个缺陷已修复，现在全部为正向断言，并补了一个用**真实机器
//  硬件端口表**做的回归测试（`testRealMachineHardwarePortMatrix`）。
//

import XCTest
@testable import FlowTrace

final class InterfaceClassifierTests: XCTestCase {

    // MARK: - 端口表分支

    // F1: "Wi-Fi" 必须识别为 .wifi
    // 回归：`port.lowercased() == "wifi"` 永不成立（真实值是 "wi-fi"），
    // 曾使本机 Wi-Fi（en1）落到 .other。
    func testWifiPort() {
        let c = InterfaceClassifier(portByDevice: ["en1": "Wi-Fi"])
        XCTAssertEqual(c.classify("en1"), .wifi)
    }

    // F2: USB 折叠为 Wired
    func testUSBTreatedAsWired() {
        let c = InterfaceClassifier(portByDevice: ["en11": "USB 10/100/1000 LAN"])
        XCTAssertEqual(c.classify("en11"), .wired)
    }

    // F3: Thunderbolt = Wired
    func testThunderboltTreatedAsWired() {
        let c = InterfaceClassifier(portByDevice: ["en5": "Thunderbolt Ethernet"])
        XCTAssertEqual(c.classify("en5"), .wired)
    }

    // F4: 纯 Ethernet 端口 = Wired
    func testEthernetPort() {
        let c = InterfaceClassifier(portByDevice: ["en0": "Ethernet"])
        XCTAssertEqual(c.classify("en0"), .wired)
    }

    // MARK: - 名称启发式（先于端口表）

    // F5: AWDL
    func testAWDL() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify("awdl0"), .localDirect)
    }

    // F6: llw0
    func testLLW0() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify("llw0"), .localDirect)
    }

    // F7: 名称大小写不敏感
    func testAWDLUppercase() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify("AWDL0"), .localDirect)
    }

    // MARK: - numeric en*

    // F8: 未在表中的动态 en* → Wired
    // 回归：`dropFirst()` 只去掉 'e'，剩下的 "n1" 含字母，曾使本分支永不可达。
    func testUnknownNumericEn() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify("en13"), .wired)
        XCTAssertEqual(c.classify("en2"), .wired)
        XCTAssertEqual(c.classify("en0"), .wired)
        XCTAssertEqual(c.classify("en1"), .wired)
    }

    // F9: enX 含字母尾 → 不命中 numeric 路径
    func testEnNonNumeric() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify("enXa"), .other)
    }

    // F10: 裸 "en"（前缀后为空）不得被当成 numeric 设备
    func testBareEnIsNotNumeric() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify("en"), .other)
    }

    // MARK: - bridge*

    // F11: bridge* → Other。同时覆盖「空表」与「真实表」两种形态：
    // 回归：bridge0 的真实端口名是 "Thunderbolt Bridge"，含 "thunderbolt"，
    // 曾让 bridge 分支永不可达（bridge 被误判为 Wired）。
    func testBridgeOther() {
        let empty = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(empty.classify("bridge100"), .other)
        XCTAssertEqual(empty.classify("bridge0"), .other)

        let real = InterfaceClassifier(portByDevice: ["bridge0": "Thunderbolt Bridge"])
        XCTAssertEqual(real.classify("bridge0"), .other,
                       "带真实端口名时 bridge 仍必须是 Other")
    }

    // MARK: - 边界

    // F12: 空 / 空白
    func testEmptyAndWhitespace() {
        let c = InterfaceClassifier(portByDevice: [:])
        XCTAssertEqual(c.classify(""), .other)
        XCTAssertEqual(c.classify("   "), .other)
    }

    // MARK: - 真实机器矩阵（回归护栏）

    /// 用本机实测采集到的 `networksetup -listallhardwareports` 输出，
    /// 逐设备锁定归类结果。三个已修复的 bug 都会在这里被立刻打回红。
    func testRealMachineHardwarePortMatrix() {
        let realTable: [String: String] = [
            "en0":     "Ethernet",
            "en5":     "Ethernet Adapter (en5)",
            "en6":     "Ethernet Adapter (en6)",
            "en10":    "Ethernet Adapter (en10)",
            "bridge0": "Thunderbolt Bridge",
            "en1":     "Wi-Fi",
            "en2":     "Thunderbolt 1",
            "en3":     "Thunderbolt 2",
            "en4":     "Thunderbolt 4",
            "en11":    "iPhone USB",
        ]
        let c = InterfaceClassifier(portByDevice: realTable)

        let expected: [String: InterfaceCategory] = [
            "en0":     .wired,        // Ethernet
            "en5":     .wired,        // Ethernet Adapter
            "en6":     .wired,
            "en10":    .wired,
            "bridge0": .other,        // Thunderbolt Bridge —— 名称优先
            "en1":     .wifi,         // Wi-Fi —— Bug #1 的回归点
            "en2":     .wired,        // Thunderbolt
            "en3":     .wired,
            "en4":     .wired,
            "en11":    .wired,        // iPhone USB 折叠进 Wired
        ]

        for (device, want) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(c.classify(device), want,
                           "\(device) (port=\(realTable[device] ?? "?")) 归类错误")
        }
    }

    /// 动态接口（不在硬件端口表里）也必须正确分类——真实流量常走这些。
    func testDynamicInterfacesNotInTable() {
        let realTable: [String: String] = [
            "en1":     "Wi-Fi",
            "bridge0": "Thunderbolt Bridge",
        ]
        let c = InterfaceClassifier(portByDevice: realTable)

        XCTAssertEqual(c.classify("en13"), .wired, "动态 en* 应归 Wired")
        XCTAssertEqual(c.classify("en7"), .wired)
        XCTAssertEqual(c.classify("bridge100"), .other, "动态 bridge* 应归 Other")
        XCTAssertEqual(c.classify("awdl0"), .localDirect)
        XCTAssertEqual(c.classify("llw0"), .localDirect)
    }
}
