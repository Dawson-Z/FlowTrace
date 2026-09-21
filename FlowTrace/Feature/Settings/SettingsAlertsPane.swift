//
//  SettingsAlertsPane.swift
//  FlowTrace — Feature/Settings
//
//  The Alerts pane: per-process traffic alerts and their thresholds.
//

import SwiftUI

// MARK: - 示警

struct SettingsAlertsPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsPane {
            SettingsRow(label: "Enable traffic alerts") {
                SettingsSwitch(isOn: uploadAlertEnabledBinding)
            }

            if settings.uploadAlertEnabled {
                SettingsRow(label: "Download multiplier (×)") {
                    EditableNumberField(
                        value: $settings.alertDownloadMultiplier,
                        range: 2...100,
                        step: 1
                    )
                }
                SettingsRow(label: "Upload multiplier (×)") {
                    EditableNumberField(
                        value: $settings.alertUploadMultiplier,
                        range: 2...100,
                        step: 1
                    )
                }
                SettingsRow(label: "Min daily download (MB)") {
                    EditableNumberField(
                        value: $settings.alertMinDownloadMB,
                        range: 1...1_000_000,
                        step: 100
                    )
                }
                SettingsRow(label: "Min daily upload (MB)") {
                    EditableNumberField(
                        value: $settings.alertMinUploadMB,
                        range: 1...1_000_000,
                        step: 100
                    )
                }
                SettingsNote(text: "Alerts when a process's daily traffic reaches the floor and exceeds its 7-day daily median by the multiplier. One alert per process per direction per day; see the alert log in history.")
            }
        }
    }

    /// Enabling traffic alerts also asks for notification permission.
    private var uploadAlertEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.uploadAlertEnabled },
            set: { on in
                settings.uploadAlertEnabled = on
                if on { ProcessAlertMonitor.requestAuthorization() }
            }
        )
    }
}
