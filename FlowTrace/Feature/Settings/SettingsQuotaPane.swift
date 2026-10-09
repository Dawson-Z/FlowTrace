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
    @StateObject private var permission = NotificationPermissionModel()

    var body: some View {
        SettingsPane {
            SettingsRow(label: "Enable quota alerts") {
                SettingsSwitch(isOn: quotaEnabledBinding)
            }

            if settings.quotaEnabled {
                NotificationPermissionWarning(model: permission)

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
                SettingsNote(text: "80% and your custom threshold alert once per period. At 100% the alert repeats while usage keeps growing (every extra 1% of the quota) — mute it from the notification if needed. Usage and alerts reset automatically at the start of each period (day / week / month).")
            }
        }
        // Panes are rebuilt on every tab switch, so appear is the reliable
        // hook: read the current authorization so the warning reflects reality
        // (covers "the toggle has been on since an earlier run" — exactly the
        // state that used to be invisible).
        .onAppear { permission.refresh() }
    }

    /// Enabling quota alerts also asks for notification permission.
    private var quotaEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.quotaEnabled },
            set: { on in
                settings.quotaEnabled = on
                if on { permission.request() }
            }
        )
    }
}
