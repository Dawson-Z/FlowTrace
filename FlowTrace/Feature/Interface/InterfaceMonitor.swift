//
//  InterfaceMonitor.swift
//  FlowTrace — Feature/Interface
//
//  A second, independent nettop process running in *socket* mode (no `-P`)
//  with the `interface` column, so each line carries the network interface
//  the bytes moved over. We aggregate those lines by `InterfaceCategory`
//  and publish a compact per-category total once per frame.
//
//  Why a second nettop?
//  --------------------
//  The primary data source (`Network`) keeps `-P` (per-process) so the
//  process list / menu bar / history stay process-level and accurate. The
//  interface view needs socket-level rows to see `interface`, so it runs
//  its own nettop instance. The two never share output — each is parsed by
//  its own parser — and both keep `-t external` so loopback (which the
//  user does not care about) stays excluded.
//
//  Threading
//  ---------
//  Mirrors NettopRunner: a private serial queue owns the Process and the
//  line buffer; lines are debounced into frames; the parsed aggregate is
//  delivered on the main queue via `onAggregate`.
//

import Foundation

/// Per-category byte totals for one interface frame (external only).
struct InterfaceSnapshot: Equatable {
    var bytesIn: [InterfaceCategory: Int] = [:]
    var bytesOut: [InterfaceCategory: Int] = [:]

    var totalIn: Int { bytesIn.values.reduce(0, +) }
    var totalOut: Int { bytesOut.values.reduce(0, +) }

    static let empty = InterfaceSnapshot()
}

final class InterfaceMonitor {

    /// Called on the main queue once per frame with the per-category totals.
    var onAggregate: ((InterfaceSnapshot) -> Void)?

    private let interval: Int
    private let debounceInterval: TimeInterval
    private let classifier: InterfaceClassifier
    private let queue = DispatchQueue(label: "interface-monitor", qos: .utility)

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var lineBuffer = Data()
    private var frameLines: [String] = []
    private var debounceWork: DispatchWorkItem?
    private var droppedFirstFrame = false
    private var shouldRestart = false

    init(interval: Int, classifier: InterfaceClassifier, debounceInterval: TimeInterval = 0.1) {
        self.interval = interval
        self.classifier = classifier
        self.debounceInterval = debounceInterval
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
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.process = nil
        }
    }

    private func spawn() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // Socket mode: NO `-P`. `-J bytes_in,bytes_out,interface` adds the
        // interface column that `-P` (per-process) drops.
        task.arguments = [
            "-q", "/dev/null",
            "/usr/bin/nettop",
            "-d",                    // delta mode
            "-L", "0",
            "-J", "bytes_in,bytes_out,interface",
            "-t", "external",        // external only — user does not want loopback
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
            Log.interface.error("failed to spawn interface monitor: \(error.localizedDescription)")
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

        // Socket mode's first frame is cumulative-since-boot, not a delta.
        guard droppedFirstFrame else {
            droppedFirstFrame = true
            return
        }

        var snapshot = InterfaceSnapshot.empty
        for line in frame {
            if let (cat, inB, outB) = parse(line) {
                snapshot.bytesIn[cat, default: 0] += inB
                snapshot.bytesOut[cat, default: 0] += outB
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onAggregate?(snapshot)
        }
    }

    /// Parse one socket-mode line: `nameAndPid,interface,bytes_in,bytes_out`.
    /// Returns nil for header / empty rows.
    private func parse(_ line: String) -> (InterfaceCategory, Int, Int)? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
        // A real row has the name in col 0, interface in col 1, bytes in
        // col 2 and 3. Header rows ("time,...") and the row that has only
        // "bytes_in,bytes_out,interface" in col 3 should be skipped.
        guard parts.count >= 4 else { return nil }
        let iface = String(parts[1]).trimmingCharacters(in: .whitespaces)
        // Skip rows with no interface: nettop emits one *process total* row
        // per process with an empty interface column, which duplicates the
        // bytes its per-socket rows (which *do* carry an interface) already
        // counted. Including both doubles every figure (observed ≈2× the
        // process-mode totals that drive the history / menu bar).
        guard !iface.isEmpty else { return nil }
        // Col 2/3 may be empty on the first frame after a socket appears;
        // treat empty as 0.
        let inBytes = Int(String(parts[2]).trimmingCharacters(in: .whitespaces)) ?? 0
        let outBytes = Int(String(parts[3]).trimmingCharacters(in: .whitespaces)) ?? 0
        // Skip header rows (part[0] starts with 'bytes' or is 'time').
        let head = String(parts[0]).trimmingCharacters(in: .whitespaces)
        if head.hasPrefix("bytes") || head == "time" { return nil }
        let category = classifier.classify(iface)
        return (category, inBytes, outBytes)
    }

    private func cleanupHandles() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        debounceWork?.cancel()
        debounceWork = nil
    }
}
