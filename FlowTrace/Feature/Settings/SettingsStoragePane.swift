//
//  SettingsStoragePane.swift
//  FlowTrace — Feature/Settings
//
//  The Storage pane: cleanup mode, retention, check-in time, and the manual
//  clear-range / clear-all history actions.
//

import SwiftUI
import AppKit

// MARK: - 存储

struct SettingsStoragePane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var l10n = LocalizationManager.shared

    /// Bounds for the manual "clear range" date pickers.
    @State private var clearFrom: Date = Calendar.current.startOfDay(for: Date())
    @State private var clearTo: Date = Calendar.current.startOfDay(for: Date())

    var body: some View {
        SettingsPane {
            SettingsRow(label: "Cleanup mode") {
                AccentPicker(
                    options: CleanupMode.allCases.map {
                        (label: Loc.l($0.labelKey), value: $0)
                    },
                    selection: cleanupModeBinding
                )
            }

            SettingsRow(label: "Retention (days)") {
                // Positive integer; the generous ceiling stands in for "no
                // maximum" (≈100 years) while keeping the field clampable.
                EditableNumberField(
                    value: $settings.historyRetentionDays,
                    range: 1...36500,
                    step: 1
                )
            }

            SettingsRow(label: "Check-in time") {
                AccentTimeField(secondsOfDay: $settings.retentionTimeOfDay)
            }

            Divider()

            // Clear history data
            Text(Loc.l("Clear history data"))
                .font(.headline)

            HStack(spacing: 8) {
                Text(Loc.l("From"))
                    .foregroundColor(.secondary)
                AccentDateField(date: $clearFrom, latest: Date())
                    .frame(width: 150)
                Text(Loc.l("To"))
                    .foregroundColor(.secondary)
                AccentDateField(date: $clearTo, latest: Date())
                    .frame(width: 150)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // Destructive actions are confirmed by an NSAlert (see
                // runClear); the buttons themselves stay standard controls.
                Button(Loc.l("Clear range…")) {
                    confirmClearRange()
                }
                .buttonStyle(.bordered)
                Button(Loc.l("Clear all…")) {
                    confirmClearAll()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Cleanup-mode picker binding. Selecting manual mode also asks for
    /// notification authorization, since reminders are delivered as local
    /// notifications.
    private var cleanupModeBinding: Binding<CleanupMode> {
        Binding(
            get: { CleanupMode(rawValue: settings.cleanupModeRaw) ?? .manualNotification },
            set: { mode in
                settings.cleanupModeRaw = mode.rawValue
                if mode == .manualNotification {
                    DataRetentionController.requestAuthorization()
                }
            }
        )
    }

    /// "Clear all…" shortcut: confirm the full-window wipe, then run it.
    private func confirmClearAll() {
        let (fromMs, toMs, fromBucket, toBucket) = Self.fullRange()
        runClear(message: Loc.l("Clear all history data?"),
                 detail: Loc.l("Every recorded usage (totals, interface, per-app) will be deleted. This cannot be undone."),
                 rangeLabel: Loc.l("all"),
                 fromMs: fromMs, toMs: toMs, fromBucket: fromBucket, toBucket: toBucket)
    }

    /// "Clear range…": confirm the selected date interval, then run it.
    private func confirmClearRange() {
        let from = min(clearFrom, clearTo)
        let to = max(clearFrom, clearTo)
        let (fromMs, toMs, fromBucket, toBucket) = Self.rangeBounds(from: from, to: to)
        let rangeText = Self.rangeLabel(from: from, to: to)
        runClear(message: Loc.l("Clear history range?"),
                 detail: String(format: Loc.l("Delete all history from %@. This cannot be undone."), rangeText),
                 rangeLabel: rangeText,
                 fromMs: fromMs, toMs: toMs, fromBucket: fromBucket, toBucket: toBucket)
    }

    /// Shared flow: count the rows to delete, show a confirmation dialog with
    /// the quantity + range, and on confirm perform the delete, log it, and
    /// show a success alert with the result detail.
    private func runClear(message: String, detail: String, rangeLabel: String,
                          fromMs: Int64, toMs: Int64, fromBucket: Int, toBucket: Int) {
        guard let persistence = SharedStore.historyPersistence else { return }
        persistence.countRange(fromMs: fromMs, toMs: toMs, fromBucket: fromBucket, toBucket: toBucket) { count in
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = message
            confirm.informativeText = "\(detail)\n\(String(format: Loc.l("%ld records to delete."), count))"
            confirm.addButton(withTitle: Loc.l("Clear"))
            confirm.addButton(withTitle: Loc.l("Cancel"))
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            persistence.deleteRange(fromMs: fromMs, toMs: toMs, fromBucket: fromBucket, toBucket: toBucket) { deleted in
                DataCleaner.resetInMemory()
                let now = ISO8601DateFormatter().string(from: Date())
                let operatorName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
                Log.settings.info("clear history by \(operatorName): range=\(rangeLabel) deleted=\(deleted) at \(now)")

                let done = NSAlert()
                done.alertStyle = .informational
                done.messageText = Loc.l("History cleared")
                done.informativeText = String(format: Loc.l("Deleted %ld records."), deleted)
                done.addButton(withTitle: Loc.l("OK"))
                done.runModal()
            }
        }
    }

    /// Full-window bounds: every row in every table.
    private static func fullRange() -> (fromMs: Int64, toMs: Int64, fromBucket: Int, toBucket: Int) {
        (0, Int64.max, 0, Int.max)
    }

    /// Convert an inclusive [from, to] local-day interval into the ms and
    /// local-minute-bucket bounds used by the two table families.
    private static func rangeBounds(from: Date, to: Date) -> (fromMs: Int64, toMs: Int64, fromBucket: Int, toBucket: Int) {
        let calendar = Calendar.current
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        let nextTo = calendar.date(byAdding: .day, value: 1, to: toDay) ?? toDay
        let fromMs = Int64(fromDay.timeIntervalSince1970 * 1000)
        let toMs = Int64(nextTo.timeIntervalSince1970 * 1000)
        let tz = Int64(TimeZone.current.secondsFromGMT()) * 1000
        let fromBucket = Int((fromMs + tz) / 60000)
        let toBucket = Int((toMs + tz) / 60000)
        return (fromMs, toMs, fromBucket, toBucket)
    }

    private static func rangeLabel(from: Date, to: Date) -> String {
        let formatter = Loc.dateFormatter(template: "yMd")
        return "\(formatter.string(from: from)) – \(formatter.string(from: to))"
    }
}
