//
//  SettingsView.swift
//  iTrafficPlus — Feature/Settings
//
//  SwiftUI form presented by `AppDelegate.showSettingsWindow()`. Single
//  source of UI for the `SettingsStore.shared` instance. We do not use
//  the macOS 13+ `Settings { }` scene because the deployment target is
//  11.0; instead we present a plain `NSWindow` wrapped around an
//  `NSHostingController`.
//
//  All user-visible strings go through `Loc.l(_:)` (localization), and the
//  "Language" picker writes `SettingsStore.languageOverride`, which
//  `LocalizationManager` reads to repaint the app in the chosen locale.
//

import SwiftUI

struct SettingsView: View {

    @ObservedObject var settings: SettingsStore

    // Observing LocalizationManager repaints the window when the user
    // changes the language override, so every Loc.l(...) re-reads.
    @ObservedObject private var l10n = LocalizationManager.shared

    // Local mirror for the interval control's instant highlight. Reading
    // `settings.refreshInterval` directly lags one event behind on a static
    // window: @Published fires objectWillChange *before* the property is
    // written, so the first click re-renders with the old value (the
    // "must tap twice" bug). @State writes repaint immediately.
    @State private var localInterval: Int = SettingsStore.shared.refreshInterval

    private let sortModeOptions: [(label: String, raw: String)] = [
        ("Name",     "name"),
        ("Download", "download"),
        ("Upload",   "upload"),
        ("Total",    "total"),
    ]

    // Language options. `nil` = follow the system; otherwise a locale id.
    private let languageOptions: [(label: String, value: String?)] = [
        ("Follow system",       nil),
        ("Simplified Chinese",  "zh-Hans"),
        ("English",             "en"),
        ("Traditional Chinese", "zh-Hant"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // MARK: - General
            Text(Loc.l("General"))
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text(Loc.l("Launch at login"))
                Spacer()
                Toggle("", isOn: $settings.launchAtLogin)
                    .labelsHidden()
            }

            HStack {
                Text(Loc.l("Default sort"))
                Spacer()
                Picker("", selection: $settings.defaultSortModeRaw) {
                    ForEach(sortModeOptions, id: \.raw) { opt in
                        Text(Loc.l(opt.label)).tag(opt.raw)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack {
                Text(Loc.l("Language"))
                Spacer()
                Picker("", selection: $settings.languageOverride) {
                    ForEach(languageOptions, id: \.label) { opt in
                        Text(Loc.l(opt.label)).tag(opt.value)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack {
                Text(Loc.l("Case-insensitive search"))
                Spacer()
                Toggle("", isOn: $settings.caseInsensitiveSearch)
                    .labelsHidden()
            }

            Divider()

            // MARK: - Status bar
            Text(Loc.l("Status bar"))
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text(Loc.l("Show download"))
                Spacer()
                Toggle("", isOn: $settings.showDownloadInStatusBar)
                    .labelsHidden()
            }
            HStack {
                Text(Loc.l("Show upload"))
                Spacer()
                Toggle("", isOn: $settings.showUploadInStatusBar)
                    .labelsHidden()
            }
            HStack {
                Text(Loc.l("Show today total"))
                Spacer()
                Toggle("", isOn: $settings.showTodayInMenuBar)
                    .labelsHidden()
            }
            HStack {
                Text(Loc.l("Show month total"))
                Spacer()
                Toggle("", isOn: $settings.showMonthInMenuBar)
                    .labelsHidden()
            }

            Divider()

            // MARK: - Quota
            Text(Loc.l("Quota"))
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text(Loc.l("Enable quota alerts"))
                Spacer()
                Toggle("", isOn: quotaEnabledBinding)
                    .labelsHidden()
            }

            if settings.quotaEnabled {
                HStack {
                    Text(Loc.l("Period"))
                    Spacer()
                    Picker("", selection: $settings.quotaPeriod) {
                        Text(Loc.l("Month")).tag("month")
                        Text(Loc.l("Week")).tag("week")
                        Text(Loc.l("Day")).tag("day")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                HStack {
                    Text(Loc.l("Limit (GB)"))
                    Spacer()
                    Stepper("", value: $settings.quotaLimitGB, in: 1...10000)
                        .labelsHidden()
                    Text("\(settings.quotaLimitGB)")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Text(Loc.l("Custom threshold (%)"))
                    Spacer()
                    Stepper("", value: $settings.quotaCustomPercent, in: 0...99)
                        .labelsHidden()
                    Text(settings.quotaCustomPercent == 0
                         ? Loc.l("Off")
                         : "\(settings.quotaCustomPercent)%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
                Text(Loc.l("Alerts fire once per period at 80%, 100% and your custom threshold."))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Divider()

            // MARK: - History
            Text(Loc.l("History"))
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text(String(format: Loc.l("Keep %ld days"), settings.historyRetentionDays))
                Spacer()
                Stepper("", value: $settings.historyRetentionDays, in: 1...30)
                    .labelsHidden()
            }

            Divider()

            // MARK: - Monitoring
            Text(Loc.l("Monitoring"))
                .font(.system(size: 13, weight: .semibold))

            // Refresh interval. A hand-rolled segmented control rather than
            // Picker(.segmented): the AppKit bridge proved flaky twice — it
            // neither refreshed segment labels on locale change nor showed
            // the clicked highlight on first tap. Plain SwiftUI buttons have
            // neither problem: highlight follows `refreshInterval` directly.
            HStack(spacing: 8) {
                Text(Loc.l("Refresh interval"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Picker(Loc.l("Refresh interval"), selection: intervalBinding) {
                    Text(Loc.l("1 second")).tag(1)
                    Text(Loc.l("2 seconds")).tag(2)
                    Text(Loc.l("5 seconds")).tag(5)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
                // The NSSegmentedControl bridge does not refresh existing
                // segment labels on locale change; rebuilding on a locale
                // switch gives fresh, correctly-localised labels.
                .id(l10n.locale)
            }

            Spacer()

            Divider()

            // MARK: - Danger
            HStack {
                Text(Loc.l("Clear all usage data"))
                    .font(.system(size: 12))
                Spacer()
                Button(Loc.l("Clear data…")) {
                    confirmClear()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(Loc.l("Done")) {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        // No fixed height: the window fits the content, so nothing is ever
        // clipped and there is no dead space when the Quota section collapses.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Confirm, then wipe every history table + reset in-memory counters.
    private func confirmClear() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Loc.l("Clear all usage data")
        alert.informativeText = Loc.l("This deletes every recorded usage (totals, interface, per-app) from this Mac. This cannot be undone.")
        alert.addButton(withTitle: Loc.l("Clear"))
        alert.addButton(withTitle: Loc.l("Cancel"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        DataCleaner.clearAll {
            Log.settings.info("user cleared all usage data")
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

    /// Selection binding for the segmented interval control. The getter
    /// reads the @State mirror (instant highlight, no @Published willSet
    /// lag); the setter writes both the mirror and the store.
    private var intervalBinding: Binding<Int> {
        Binding(
            get: { localInterval },
            set: { new in
                localInterval = new                   // instant highlight
                settings.refreshInterval = new        // data layer: defaults + Network sink
            }
        )
    }
}
