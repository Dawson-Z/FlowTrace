//
//  UploadAnomalyMonitor.swift
//  iTrafficPlus — Feature/Usage
//
//  Fires a local notification when a process's upload rate spikes well above
//  its own recent baseline (e.g. a hidden background process starts pushing
//  data). Pure decision logic is exposed for standalone testing; the class
//  owns a private serial queue and thread-safe per-process state.
//
//  Rules:
//    - baseline = median of the last `baselineWindow` non-zero upload frames
//    - fire when upload >= median * multiplier  AND  upload >= minBytesPerSec
//    - ...and this has held for `consecutiveFrames` frames (debounce spikes)
//    - not until the baseline has `minBaselineSamples` samples (cold start)
//    - cooldown: no repeat for the same process for `cooldownSeconds`
//

import Foundation
import UserNotifications

final class UploadAnomalyMonitor: ObservableObject {

    // MARK: - Pure decision logic (mirrored in verify_upload_anomaly.swift)

    struct Decision {
        let median: Int
        let baselineSamples: Int
        let threshold: Int
        let isSpike: Bool
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func decide(upload: Int, baseline: [Int], multiplier: Int, minBytesPerSec: Int) -> Decision {
        let med = median(baseline)
        let samples = baseline.count
        // Cold start: not enough baseline to judge an anomaly.
        let threshold = med * multiplier
        let isSpike = samples >= 5
            && med > 0
            && upload >= threshold
            && upload >= minBytesPerSec
        return Decision(median: med, baselineSamples: samples, threshold: threshold, isSpike: isSpike && threshold > 0)
    }

    // MARK: - Instance state (private serial queue)

    private struct ProcessState {
        var baseline: [Int] = []           // last N non-zero uploads
        var consecutive = 0                // frames that have been a spike
        var lastNotifiedAt: Date? = nil
    }

    private let queue = DispatchQueue(label: "upload-anomaly-monitor", qos: .utility)
    private var states: [String: ProcessState] = [:]
    private let settings: SettingsStore

    private let baselineWindow = 15
    private let minBaselineSamples = 5
    private let consecutiveFrames = 3
    private let cooldownSeconds: TimeInterval = 30 * 60

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    /// Feed one frame's normalised process rates (called from the main
    /// queue's frame handler; work is dispatched to the private queue).
    func feed(entities: [ProcessEntity], now: Date) {
        guard settings.uploadAlertEnabled, !entities.isEmpty else { return }
        let multiplier = max(2, settings.uploadAlertMultiplier)
        let minBytesPerSec = Int(max(0.1, settings.uploadAlertMinMBps) * 1024 * 1024)

        queue.async { [weak self] in
            guard let self else { return }
            for entity in entities {
                let upload = entity.outBytesPerSec
                let key = entity.name.lowercased()
                var state = self.states[key] ?? ProcessState()

                // Zero uploads don't inform the baseline, but do reset the
                // consecutive-spike counter (the burst ended).
                if upload <= 0 {
                    state.consecutive = 0
                    self.states[key] = state
                    continue
                }

                state.baseline.append(upload)
                if state.baseline.count > self.baselineWindow {
                    state.baseline.removeFirst()
                }

                let decision = Self.decide(upload: upload, baseline: state.baseline,
                                           multiplier: multiplier, minBytesPerSec: minBytesPerSec)
                if decision.isSpike {
                    state.consecutive += 1
                    if state.consecutive >= self.consecutiveFrames,
                       self.cooldownElapsed(for: state) {
                        self.fire(process: entity.name, rate: upload)
                        state.lastNotifiedAt = now
                        state.consecutive = 0   // reset after notifying
                    }
                } else {
                    state.consecutive = 0
                }

                self.states[key] = state
            }
        }
    }

    private func cooldownElapsed(for state: ProcessState) -> Bool {
        guard let last = state.lastNotifiedAt else { return true }
        return Date().timeIntervalSince(last) >= cooldownSeconds
    }

    private func fire(process: String, rate: Int) {
        let rateStr = formatBytesCompact(bytes: rate)
        let content = UNMutableNotificationContent()
        content.title = Loc.l("Abnormal upload")
        content.body = String(format: Loc.l("%@ is uploading fast (%@/s), above its usual baseline."), process, rateStr)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "upload-anomaly-\(process.lowercased())",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Request notification authorization (call when the user enables alerts).
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.l10n.info("auth result granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
        }
    }
}
