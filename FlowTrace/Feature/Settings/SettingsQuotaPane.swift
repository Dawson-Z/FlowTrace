//
//  SettingsQuotaPane.swift
//  FlowTrace — Feature/Settings
//
//  The Quota pane: period quota alerts, limit and custom threshold.
//

import SwiftUI

// MARK: - 配额

struct SettingsQuotaPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        SettingsPane {
            SettingsRow(label: "Enable quota alerts") {
                SettingsSwitch(isOn: quotaEnabledBinding)
            }

            if settings.quotaEnabled {
                SettingsRow(label: "Period") {
                    AccentPicker(
                        options: [("Month", "month"), ("Week", "week"), ("Day", "day")]
                            .map { (label: Loc.l($0.0), value: $0.1) },
                        selection: $settings.quotaPeriod
                    )
                }
                SettingsRow(label: "Limit (GB)") {
                    EditableNumberField(
                        value: $settings.quotaLimitGB,
                        range: 1...10000,
                        step: 1
                    )
                }
                SettingsRow(label: "Custom threshold (%)") {
                    EditableNumberField(
                        value: $settings.quotaCustomPercent,
                        range: 0...99,
                        step: 1
                    )
                }
                SettingsNote(text: "Alerts fire once per period at 80%, 100% and your custom threshold.")
            }
        }
    }

    /// Enabling quota alerts also asks for notification permission.
    private var quotaEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.quotaEnabled },
            set: { on in
                settings.quotaEnabled = on
                if on { QuotaMonitor.requestAuthorization() }
            }
        )
    }
}
