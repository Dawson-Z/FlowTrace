//
//  InterfaceTopMonitor.swift
//  iTrafficPlus — Feature/Interface
//
//  Runs one nettop subprocess per interface *type* (Wi-Fi / Wired / AWDL),
//  each with `-P -t <type>`, so the output is process-level for that type.
//  We parse each frame into the top N processes by total bytes and publish
//  a per-type snapshot on the main queue.
//
//  Why not reuse InterfaceMonitor (socket mode)?
//  ---------------------------------------------
//  Socket mode gives interface names but no process names (col 0 is the
//  socket description). The user wants "which process uses which interface
//  type", so we need process rows *for* a given `-t` type, which only
//  `-P -t <type>` provides. Trade-off: `-t` has no 'usb' type, so USB
//  devices (en11) fall under 'wired', which the user accepted.
//
//  Threading
//  ---------
//  Each type gets its own serial queue + Process + line buffer, mirroring
//  NettopRunner's TTY wrap, debounce, first-frame drop and auto-restart.
//  Parsed snapshots are delivered on the main queue via the callback.
//

import Foundation

final class InterfaceTopMonitor {

    /// Called on the main queue once per frame with all type snapshots.
    var onSnapshot: (([InterfaceTopSnapshot]) -> Void)?

    private let interval: Int
    private let debounceInterval: TimeInterval
    private let topCount: Int

    init(interval: Int, debounceInterval: TimeInterval = 0.1, topCount: Int = 5) {
        self.interval = interval
        self.debounceInterval = debounceInterval
        self.topCount = topCount
    }

    // MARK: - Per-type runner

    /// One nettop subprocess (`-P -t <type>`) + its own serial queue.
    private final class TypeRunner {
        let type: InterfaceTopType
        let queue: DispatchQueue
        let interval: Int
        let debounceInterval: TimeInterval
        let topCount: Int

        var process: Process?
        var stdinPipe: Pipe?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?
        var lineBuffer = Data()
        var frameLines: [String] = []
        var debounceWork: DispatchWorkItem?
        var droppedFirstFrame = false
        var shouldRestart = false

        /// Called on main queue with this type's parsed snapshot.
        var onFrame: ((InterfaceTopType, [InterfaceTopProcess], Int, Int) -> Void)?

        init(type: InterfaceTopType, interval: Int, debounceInterval: TimeInterval, topCount: Int) {
            self.type = type
            self.interval = interval
            self.debounceInterval = debounceInterval
            self.topCount = topCount
            self.queue = DispatchQueue(label: "interface-top-\(type.nettopArgument)", qos: .utility)
        }

        func start() {
            queue.async { [weak self] in
                guard let self else { return }
                self.shouldRestart = true
                self.spawn()
            }
        }

        func stop() {
            queue.async { [weak self] in
                guard let self else { return }
                self.shouldRestart = false
                self.process?.terminationHandler = nil
                self.process?.terminate()
                self.cleanupHandles()
                self.process = nil
            }
        }

        private func spawn() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            task.arguments = [
                "-q", "/dev/null",
                "/usr/bin/nettop",
                "-P",                    // per-process
                "-d",
                "-L", "0",
                "-J", "bytes_in,bytes_out",
                "-t", type.nettopArgument,
                "-s", "\(interval)",
                "-c"
            ]

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardInput = stdin
            task.standardOutput = stdout
            task.standardError = stderr
            self.stdinPipe = stdin
            self.stdoutPipe = stdout
            self.stderrPipe = stderr

            self.lineBuffer.removeAll(keepingCapacity: true)
            self.frameLines.removeAll(keepingCapacity: true)
            self.droppedFirstFrame = false

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                self.queue.async { self.consume(data) }
            }

            task.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.cleanupHandles()
                    guard self.shouldRestart else { return }
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.spawn()
                    }
                }
            }

            do {
                try task.run()
                self.process = task
            } catch {
                Log.interface.error("top[\(self.type.nettopArgument)] failed to spawn: \(error.localizedDescription)")
                if shouldRestart {
                    queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.spawn()
                    }
                }
            }
        }

        private func consume(_ data: Data) {
            lineBuffer.append(data)
            while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    frameLines.append(trimmed)
                }
            }
            scheduleFlush()
        }

        private func scheduleFlush() {
            debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushFrame() }
            debounceWork = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }

        private func flushFrame() {
            guard !frameLines.isEmpty else { return }
            let frame = frameLines
            frameLines.removeAll(keepingCapacity: true)

            guard droppedFirstFrame else {
                droppedFirstFrame = true
                return
            }

            var processes: [InterfaceTopProcess] = []
            var totalIn = 0
            var totalOut = 0
            for line in frame {
                // `-P -t <type>` line: nameAndPid, bytes_in, bytes_out
                guard let parsed = parse(line) else { continue }
                totalIn += parsed.inBytesPerSec
                totalOut += parsed.outBytesPerSec
                processes.append(parsed)
            }
            // Sort by total bytes descending; keep the top N.
            processes.sort { $0.totalBytesPerSec > $1.totalBytesPerSec }
            let top = Array(processes.prefix(topCount))

            let type = self.type
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(type, top, totalIn, totalOut)
            }
        }

        /// Parse one `-P -t <type>` line: `name.pid,bytes_in,bytes_out`.
        private func parse(_ line: String) -> InterfaceTopProcess? {
            let items = line.split(separator: ",", omittingEmptySubsequences: false)
            guard items.count >= 3 else { return nil }
            let namePid = String(items[0]).trimmingCharacters(in: .whitespaces)
            guard let pid = Int(namePid.split(separator: ".").last ?? "") else { return nil }
            let name = namePid.split(separator: ".").dropLast().joined(separator: ".")
            let inB = Int(String(items[1]).trimmingCharacters(in: .whitespaces)) ?? 0
            let outB = Int(String(items[2]).trimmingCharacters(in: .whitespaces)) ?? 0
            return InterfaceTopProcess(
                pid: pid,
                name: name.isEmpty ? namePid : name,
                inBytesPerSec: inB,
                outBytesPerSec: outB
            )
        }

        private func cleanupHandles() {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            debounceWork?.cancel()
            debounceWork = nil
        }
    }

    // MARK: - Container

    private var runners: [TypeRunner] = []

    func start() {
        stop()
        var runners: [TypeRunner] = []
        for type in InterfaceTopType.allCases {
            let runner = TypeRunner(type: type, interval: interval, debounceInterval: debounceInterval, topCount: topCount)
            runner.onFrame = { [weak self] t, procs, tin, tout in
                guard let self else { return }
                self.collect(t, procs, tin, tout)
            }
            runners.append(runner)
            runner.start()
        }
        self.runners = runners
    }

    func stop() {
        for r in runners { r.stop() }
        runners = []
    }

    /// Buffering per-type snapshots until all three have fired for a frame,
    /// then publish them together. nettop types may flush a moment apart.
    private var pending: [InterfaceTopType: InterfaceTopSnapshot] = [:]
    private var flushWork: DispatchWorkItem?

    private func collect(_ type: InterfaceTopType, _ procs: [InterfaceTopProcess], _ tin: Int, _ tout: Int) {
        pending[type] = InterfaceTopSnapshot(
            type: type,
            topProcesses: procs,
            totalInBytesPerSec: tin,
            totalOutBytesPerSec: tout
        )
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.publish()
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func publish() {
        // Publish whatever we have; missing types this frame default to empty.
        let snapshots = InterfaceTopType.allCases.map { type in
            pending[type] ?? InterfaceTopSnapshot(type: type, topProcesses: [], totalInBytesPerSec: 0, totalOutBytesPerSec: 0)
        }
        onSnapshot?(snapshots)
    }
}
