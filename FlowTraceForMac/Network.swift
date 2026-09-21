//
//  Network.swift
//  FlowTrace
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import SwiftUI
import Combine

class Network {
    @ObservedObject var viewModel = SharedStore.listViewModel
    @ObservedObject var statusDataModel = SharedStore.statusDataModel
    @ObservedObject var globalModel = SharedStore.globalModel
    @ObservedObject var historyStore = SharedStore.historyStore

    /// Nettopp sample interval in seconds. Fixed at 1 s to match Activity
    /// Monitor's default refresh; the settings UI no longer offers a choice,
    /// so it never changes at runtime — hence a `let`.
    private let interval: Int = SettingsStore.shared.refreshInterval
    private var cancellables: Set<AnyCancellable> = []

    /// Built on demand by the factory methods so an interval change can
    /// rebuild every subprocess with the new `-s` value.
    private var runner: NettopRunner?
    private var interfaceMonitor: InterfaceMonitor?

    /// Per-minute process usage accumulator (per-app usage history).
    private lazy var usageAggregator = ProcessUsageAggregator {
        SharedStore.historyPersistence
    }

    private func makeRunner() -> NettopRunner {
        let r = NettopRunner(interval: interval)
        r.onFrame = { [weak self] lines in
            self?.handleFrame(lines)
        }
        return r
    }

    private func makeInterfaceMonitor() -> InterfaceMonitor {
        let classifier = InterfaceClassifier()
        let m = InterfaceMonitor(interval: interval, classifier: classifier)
        m.onAggregate = { [weak self] snapshot in
            SharedStore.interfaceModel.update(snapshot)
            // Live per-category "usage today" (day base + this frame's delta).
            SharedStore.interfaceModel.trackTodayFrame(snapshot)
            // Minute-bucket accumulator for the history window's heatmap.
            SharedStore.interfaceMinuteAggregator.feed(snapshot, now: Date(),
                                                       persistence: SharedStore.historyPersistence)

            // Persist per-category rates for the history heatmap. The
            // snapshot carries *window deltas* (bytes over one sample), so
            // normalise once here — the single point where interface numbers
            // enter the app — dividing by the current interval. Downstream
            // readers must never divide again (see issue #28).
            guard let self, let persistence = SharedStore.historyPersistence else { return }
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            let rows: [InterfaceHistoryRow] = InterfaceCategory.allCases.compactMap { cat in
                let inDelta = snapshot.bytesIn[cat] ?? 0
                let outDelta = snapshot.bytesOut[cat] ?? 0
                guard inDelta != 0 || outDelta != 0 else { return nil }
                return InterfaceHistoryRow(
                    ts: ts,
                    category: cat.rawValue,
                    inBytesPerSec: inDelta / self.interval,
                    outBytesPerSec: outDelta / self.interval
                )
            }
            persistence.appendInterface(rows)
        }
        Log.interface.info("interface monitor launched; ports=\(classifier.portByDevice)")
        return m
    }

    public func startListenNetwork() {
        // os.log's `info(_:)` takes an `OSLogMessage`, not a `String`, and
        // interpolation values default to .private — visible to the running
        // process only. Adding `privacy: .public` makes the value stream to
        // Console.app and `log stream`. Literal string parts are always
        // public; only the `\(...)` slot needs the explicit privacy.
        let cap = self.historyStore.capacity
        Log.network.info("NettopRunner starting; history capacity=\(cap); interval=\(interval)s")

        runner = makeRunner()
        interfaceMonitor = makeInterfaceMonitor()
        runner?.start()
        interfaceMonitor?.start()
    }

    public func stopListenNetwork() {
        runner?.stop()
        interfaceMonitor?.stop()
        runner = nil
        interfaceMonitor = nil
        cancellables.removeAll()
    }

    private func handleFrame(_ lines: [String]) {
        tryToMakeAppSleepDeep()

        var totalInRate = 0
        var totalOutRate = 0
        let entities: [ProcessEntity] = lines.compactMap { line -> ProcessEntity? in
            guard let entity = parser(text: line) else { return nil }
            totalInRate += entity.inBytesPerSec
            totalOutRate += entity.outBytesPerSec
            return entity
        }

        // Per-app usage history: accumulate this frame into the current
        // minute bucket (flush happens inside on minute rollover).
        usageAggregator.feed(entities: entities, interval: interval, now: Date())
        // Period totals for quota + menu bar (throttled internally).
        SharedStore.usageAggregator.tick()
        // Per-process daily traffic alerts (no-op when disabled).
        SharedStore.processAlertMonitor.feed(entities: entities, interval: interval, now: Date())

        DispatchQueue.main.async {
            // History is pushed *before* the per-frame observers so the sparkline
            // catches the same totals the menu bar and list will see.
            self.historyStore.append(inBytesPerSec: totalInRate, outBytesPerSec: totalOutRate)
            self.statusDataModel.update(totalInBytesPerSec: totalInRate, totalOutBytesPerSec: totalOutRate)
            // Live per-process "today" cumulative (base + this frame's delta),
            // published before updateData so a cumulative sort sees fresh totals.
            SharedStore.listViewModel.trackTodayUsage(entities: entities, interval: self.interval)
            self.viewModel.updateData(newItems: entities)
        }
    }

    var sleepCounter = 0
    let MAX_COUNT = 30
    func tryToMakeAppSleepDeep() {
        if !globalModel.viewShowing && sleepCounter >= MAX_COUNT {
            globalModel.isSleepDeep = true
            if globalModel.controllerHaveBeenReleased == false {
                Log.network.info("entering deep sleep; releasing popover controller")
                DispatchQueue.main.async {
                    AppDelegate.popover.contentViewController = nil
                }
                globalModel.controllerHaveBeenReleased = true
            }
            return
        }
        if sleepCounter >= MAX_COUNT {
            sleepCounter = 0
        }
        if !globalModel.viewShowing {
            sleepCounter += 1
        }
        globalModel.isSleepDeep = false
    }

    /// nettop runs in delta mode (`-d`) on an `interval`-second sample, so every
    /// frame reports the bytes moved across that whole window. Normalise to
    /// bytes/sec right here, at the single point where raw nettop numbers enter
    /// the app — the status bar and the process list then read the same unit.
    ///
    /// Do not move this divide "up" to the aggregation point: 0.2.0 did exactly
    /// that, and the popover list kept rendering raw 2-second deltas, i.e. double
    /// the menu bar's rate (issue #28).
    func parser(text: String) -> ProcessEntity? {
        let item = text.split(separator: ",")
        if item.count < 3 {
            return nil
        }
        let inBytesPerSec  = (Int(item[1]) ?? 0) / interval
        let outBytesPerSec = (Int(item[2]) ?? 0) / interval

        let nameAndPid = item[0].split(separator: ".")
        guard nameAndPid.count >= 2 else {
            return nil
        }
        let pid = nameAndPid[nameAndPid.count - 1]
        var name = nameAndPid
        name.removeLast()

        return ProcessEntity(
            pid: Int(pid) ?? 0,
            name: name.joined(separator: "."),
            inBytesPerSec: inBytesPerSec,
            outBytesPerSec: outBytesPerSec
        )
    }
}
