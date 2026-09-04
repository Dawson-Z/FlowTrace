//
//  Network.swift
//  iTrafficPlus
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

    /// Current sample interval (seconds). Re-read from Settings so a change
    /// in the Settings window can take effect via `applyRefreshInterval()`.
    private(set) var interval: Int = SettingsStore.shared.refreshInterval
    private var cancellables: Set<AnyCancellable> = []

    /// Built on demand by the factory methods so an interval change can
    /// rebuild every subprocess with the new `-s` value.
    private var runner: NettopRunner?
    private var interfaceMonitor: InterfaceMonitor?
    private var interfaceTopMonitor: InterfaceTopMonitor?

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
        }
        Log.interface.info("interface monitor launched; ports=\(classifier.portByDevice)")
        return m
    }

    private func makeInterfaceTopMonitor() -> InterfaceTopMonitor {
        let m = InterfaceTopMonitor(interval: interval)
        m.onSnapshot = { [weak self] snapshots in
            SharedStore.interfaceModel.updateTop(snapshots)
        }
        Log.interface.info("interface top monitor launched (types=\(InterfaceTopType.allCases.map(\.nettopArgument)))")
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
        interfaceTopMonitor = makeInterfaceTopMonitor()
        runner?.start()
        interfaceMonitor?.start()
        interfaceTopMonitor?.start()

        // Milestone 11: react to refresh-interval changes in Settings by
        // rebuilding every nettop subprocess with the new `-s` value.
        SettingsStore.shared.$refreshInterval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyRefreshInterval()
            }
            .store(in: &cancellables)
    }

    public func stopListenNetwork() {
        runner?.stop()
        interfaceMonitor?.stop()
        interfaceTopMonitor?.stop()
        runner = nil
        interfaceMonitor = nil
        interfaceTopMonitor = nil
        cancellables.removeAll()
    }

    /// Restart every nettop subprocess so the sample interval takes effect.
    /// A shorter interval makes the UI refresh more often but costs more
    /// nettop CPU; the rate normalisation in `parser` reads `interval`, so
    /// it must be current before the new subprocesses produce frames.
    private func applyRefreshInterval() {
        let newInterval = SettingsStore.shared.refreshInterval
        guard newInterval != interval else { return }
        interval = newInterval
        Log.network.info("refresh interval changed to \(newInterval)s; restarting collectors")
        runner?.stop()
        interfaceMonitor?.stop()
        interfaceTopMonitor?.stop()
        runner = makeRunner()
        interfaceMonitor = makeInterfaceMonitor()
        interfaceTopMonitor = makeInterfaceTopMonitor()
        runner?.start()
        interfaceMonitor?.start()
        interfaceTopMonitor?.start()
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

        DispatchQueue.main.async {
            // History is pushed *before* the per-frame observers so the sparkline
            // catches the same totals the menu bar and list will see.
            self.historyStore.append(inBytesPerSec: totalInRate, outBytesPerSec: totalOutRate)
            self.statusDataModel.update(totalInBytesPerSec: totalInRate, totalOutBytesPerSec: totalOutRate)
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
