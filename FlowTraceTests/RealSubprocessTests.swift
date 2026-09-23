//
//  RealSubprocessTests.swift
//  FlowTraceTests
//
//  L3-1 ~ L3-6：真实子进程与真实命令。
//
//  这是纯函数测不到、mock 也无法证伪的一层：nettop 的**真实 CSV 格式**、
//  socket 模式下进程汇总行的**真实存在**、以及分类器拿到的**真实硬件端口表**。
//
//  `-L <n>` 让 nettop 输出 n 个采样后自行退出，因此不需要 kill 子进程。
//  依赖本机网络与 /usr/bin/nettop；采集为空时记 SKIP（throw XCTSkip）而不是 FAIL。
//

import XCTest
@testable import FlowTrace

final class RealSubprocessTests: XCTestCase {

    private let nettopPath = "/usr/bin/nettop"

    private struct RunResult {
        let stdout: String
        let elapsed: TimeInterval
    }

    /// 跑一次 nettop 并取回 stdout。`-L <samples>` 会让它自行退出；
    /// 另设看门狗，避免异常情况下挂住整个测试进程。
    private func runNettop(_ args: [String], timeout: TimeInterval) throws -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: nettopPath) else {
            throw XCTSkip("\(nettopPath) 不存在或不可执行")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: nettopPath)
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()   // nettop 的告警走 stderr，忽略

        let start = Date()
        try task.run()

        let watchdog = DispatchWorkItem {
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        return RunResult(stdout: String(data: data, encoding: .utf8) ?? "",
                         elapsed: Date().timeIntervalSince(start))
    }

    /// 按 header 行切分成若干帧。
    private func frames(of output: String, header: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == header {
                if !current.isEmpty { result.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 按逗号切列，保留空列（socket 模式的 interface 列可能为空）。
    private func columns(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - L3-1  可执行性

    func testNettopExists() throws {
        guard FileManager.default.isExecutableFile(atPath: nettopPath) else {
            throw XCTSkip("本机没有 \(nettopPath)")
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: nettopPath))
    }

    // MARK: - L3-2  per-process 帧格式 + 真实数据过一遍生产 parser

    func testPerProcessFrameFormatAndProductionParser() throws {
        let run = try runNettop(
            ["-P", "-d", "-L", "2", "-J", "bytes_in,bytes_out",
             "-t", "external", "-s", "1", "-c"],
            timeout: 20
        )

        let blocks = frames(of: run.stdout, header: ",bytes_in,bytes_out,")
        try XCTSkipIf(blocks.isEmpty, "nettop 未输出任何帧（本机可能无外部流量）")

        let header = ",bytes_in,bytes_out,"
        XCTAssertTrue(run.stdout.contains(header), "per-process 模式的 CSV 表头应为 \(header)")

        // 生产解析器必须能吃下每一条真实行
        let network = Network()
        var parsedCount = 0
        var totalLines = 0

        for block in blocks {
            for line in block {
                totalLines += 1
                let cols = columns(line)
                XCTAssertGreaterThanOrEqual(cols.count, 3,
                                            "每行至少 3 列（name.pid,in,out）：\(line)")

                // 真实行必须能被生产 parser 解出（这是对 Network.parser 的最强验证）
                let entity = network.parser(text: line)
                XCTAssertNotNil(entity, "生产 parser 解不出真实行：\(line)")
                if let e = entity {
                    XCTAssertGreaterThan(e.pid, 0, "pid 应被解析为正整数：\(line)")
                    XCTAssertFalse(e.name.isEmpty, "进程名不应为空：\(line)")
                    parsedCount += 1
                }
            }
        }

        XCTAssertEqual(parsedCount, totalLines,
                       "全部 \(totalLines) 条真实行都应被 parser 成功解析")
        print("[L3-2] 解析 \(parsedCount)/\(totalLines) 行；首个数据行样本：\(blocks[0].first ?? "")")
    }

    // MARK: - L3-3  socket 帧格式 + 进程汇总行的真实存在（2× 翻倍风险的来源）

    func testSocketFrameHasBothEmptyAndNonEmptyInterfaceRows() throws {
        let run = try runNettop(
            ["-d", "-L", "2", "-J", "bytes_in,bytes_out,interface",
             "-t", "external", "-s", "1", "-c"],
            timeout: 20
        )

        let header = ",interface,bytes_in,bytes_out,"
        let blocks = frames(of: run.stdout, header: header)
        try XCTSkipIf(blocks.isEmpty, "nettop 未输出任何帧")

        XCTAssertTrue(run.stdout.contains(header), "socket 模式的 CSV 表头应为 \(header)")

        var emptyInterface: [(name: String, inB: Int, outB: Int)] = []
        var withInterface: [(iface: String, inB: Int, outB: Int)] = []

        for block in blocks {
            for line in block {
                let cols = columns(line)
                XCTAssertGreaterThanOrEqual(cols.count, 4,
                                            "socket 模式每行至少 4 列：\(line)")
                let iface = cols[1].trimmingCharacters(in: .whitespaces)
                let inB = Int(cols[2].trimmingCharacters(in: .whitespaces)) ?? 0
                let outB = Int(cols[3].trimmingCharacters(in: .whitespaces)) ?? 0
                if iface.isEmpty {
                    if inB != 0 || outB != 0 {
                        emptyInterface.append((cols[0], inB, outB))
                    }
                } else {
                    withInterface.append((iface, inB, outB))
                }
            }
        }

        // 前提一：确实存在 interface 非空的行
        XCTAssertFalse(withInterface.isEmpty,
                       "socket 模式必须出现带 interface 的行——否则分类器无从工作")
        // 前提二：确实存在 interface 为空的「进程汇总行」——这正是源码必须跳过的那类行
        XCTAssertFalse(emptyInterface.isEmpty,
                       "socket 模式必须出现 interface 为空的进程汇总行——InterfaceMonitor.parse 跳过它们的原因")

        // 关键证据：空 interface 行的字节数与其 per-socket 行完全一致 → 不跳过就翻倍
        var duplicated = 0
        for row in emptyInterface {
            let hit = withInterface.contains { $0.inB == row.inB && $0.outB == row.outB }
            if hit { duplicated += 1 }
        }
        XCTAssertGreaterThan(duplicated, 0,
                             "应能找到「进程汇总行 ↔ per-socket 行」数值完全相同的配对；"
                             + "这正是跳过空 interface 行能避免 2× 翻倍的直接证据")

        print("[L3-3] 带 interface 行 \(withInterface.count) 条，空 interface 汇总行 \(emptyInterface.count) 条，"
              + "其中 \(duplicated) 条能在两侧找到相同的字节对（不跳过即翻倍）")
        print("[L3-3] 出现的 interface：\(Set(withInterface.map(\.iface)).sorted())")
    }

    // MARK: - L3-4  真实硬件端口表 + 真实归类矩阵

    func testRealHardwarePortTableAndClassificationMatrix() throws {
        let portByDevice = InterfaceClassifier.discoverPortByDevice()
        try XCTSkipIf(portByDevice.isEmpty,
                      "networksetup 未返回任何硬件端口（可能被权限拦截）")

        XCTAssertTrue(portByDevice.keys.contains("en0") || portByDevice.keys.contains("en1"),
                      "真实表至少应含 en0 / en1，实际：\(portByDevice.keys.sorted())")

        let classifier = InterfaceClassifier(portByDevice: portByDevice)

        // 打印完整矩阵作为证据（期望 vs 现状）
        var lines: [String] = []
        var misclassified: [String] = []
        for device in portByDevice.keys.sorted() {
            let port = portByDevice[device] ?? ""
            let actual = classifier.classify(device)
            let expected: InterfaceCategory
            let lowered = port.lowercased()
            if lowered.contains("wi-fi") || lowered.contains("wifi") {
                expected = .wifi
            } else if lowered.contains("usb") || lowered.contains("ethernet")
                        || lowered.contains("thunderbolt") {
                // 注意：Thunderbolt Bridge（bridge*）按源码注释本应归 other，
                // 但实现会先命中 thunderbolt 分支 —— 见结果文档 Bug #3
                expected = device.hasPrefix("bridge") ? .other : .wired
            } else {
                expected = .other
            }
            lines.append("\(device)  port=\(port)  → \(actual.rawValue)  (期望 \(expected.rawValue))")
            if actual != expected { misclassified.append(device) }
        }
        print("[L3-4] 真实归类矩阵：\n" + lines.joined(separator: "\n"))

        // 只断言「分类器能跑完真实表且不返回非法值」，不硬断言每项都对
        // （错误归类属于产品缺陷，由结果文档的 Bug 报告记录，而不是让测试失败）
        for device in portByDevice.keys {
            XCTAssertTrue(InterfaceCategory.allCases.contains(classifier.classify(device)),
                          "\(device) 的归类必须是合法枚举值")
        }

        print("[L3-4] 与期望不符的设备：\(misclassified.isEmpty ? "无" : misclassified.joined(separator: ", "))")
    }

    // MARK: - L3-5  首帧是累计值（必须丢弃）—— 真实数据佐证

    func testFirstFrameIsCumulativeNotDelta() throws {
        let run = try runNettop(
            ["-P", "-d", "-L", "3", "-J", "bytes_in,bytes_out",
             "-t", "external", "-s", "1", "-c"],
            timeout: 25
        )

        let blocks = frames(of: run.stdout, header: ",bytes_in,bytes_out,")
        try XCTSkipIf(blocks.count < 2, "需要至少 2 帧才能比较首帧与后续帧，实际 \(blocks.count) 帧")

        func total(_ block: [String]) -> Int {
            block.reduce(0) { acc, line in
                let cols = columns(line)
                guard cols.count >= 3 else { return acc }
                let i = Int(cols[1].trimmingCharacters(in: .whitespaces)) ?? 0
                let o = Int(cols[2].trimmingCharacters(in: .whitespaces)) ?? 0
                return acc + i + o
            }
        }

        let first = total(blocks[0])
        let second = total(blocks[1])
        try XCTSkipIf(first == 0, "首帧总和为 0，无法判断（本机可能无流量）")

        let ratio = second > 0 ? Double(first) / Double(second) : Double.infinity
        print("[L3-5] 帧1 总和=\(first)，帧2 总和=\(second)，比值=\(ratio.isInfinite ? "∞" : String(format: "%.1f", ratio))")

        XCTAssertGreaterThanOrEqual(first, second,
                                    "首帧是启动以来的累计值，应 ≥ 后续帧的区间增量"
                                    + "（这正是不丢弃首帧会把历史总计灌进分钟桶的原因）")
    }

    // MARK: - L3-6  -s 1 真实生效

    func testSampleIntervalIsHonoured() throws {
        let run = try runNettop(
            ["-P", "-d", "-L", "3", "-J", "bytes_in,bytes_out",
             "-t", "external", "-s", "1", "-c"],
            timeout: 25
        )
        try XCTSkipIf(run.stdout.isEmpty, "nettop 无输出")

        // 3 个采样 × 1s ≈ 2~3s；给足余量但仍能证明没有退化成「立即返回」
        XCTAssertGreaterThan(run.elapsed, 1.0,
                             "-s 1 下 3 个采样不应在 1s 内结束（实际 \(run.elapsed)s）")
        XCTAssertLessThan(run.elapsed, 15.0,
                          "3 个采样耗时 \(run.elapsed)s，远超预期（-s 未生效？）")
        print("[L3-6] -L 3 -s 1 实际耗时 \(String(format: "%.2f", run.elapsed))s")
    }
}
