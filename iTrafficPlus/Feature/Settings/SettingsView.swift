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

import SwiftUI

struct SettingsView: View {

    @ObservedObject var settings: SettingsStore

    private let sortModeOptions: [(label: String, raw: String)] = [
        ("Total",    "total"),
        ("Download", "download"),
        ("Upload",   "upload"),
        ("Name",     "name"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // MARK: - General
            Text("General")
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text("Launch at login")
                Spacer()
                Toggle("", isOn: $settings.launchAtLogin)
                    .labelsHidden()
            }

            HStack {
                Text("Default sort")
                Spacer()
                Picker("", selection: $settings.defaultSortModeRaw) {
                    ForEach(sortModeOptions, id: \.raw) { opt in
                        Text(opt.label).tag(opt.raw)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack {
                Text("Case-insensitive search")
                Spacer()
                Toggle("", isOn: $settings.caseInsensitiveSearch)
                    .labelsHidden()
            }

            Divider()

            // MARK: - Status bar
            Text("Status bar")
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text("Show download")
                Spacer()
                Toggle("", isOn: $settings.showDownloadInStatusBar)
                    .labelsHidden()
            }
            HStack {
                Text("Show upload")
                Spacer()
                Toggle("", isOn: $settings.showUploadInStatusBar)
                    .labelsHidden()
            }

            Divider()

            // MARK: - History
            Text("History")
                .font(.system(size: 13, weight: .semibold))

            HStack {
                Text("Keep \(settings.historyRetentionDays) day\(settings.historyRetentionDays == 1 ? "" : "s")")
                Spacer()
                Stepper("", value: $settings.historyRetentionDays, in: 1...30)
                    .labelsHidden()
            }

            Divider()

            // MARK: - Monitoring
            Text("Monitoring")
                .font(.system(size: 13, weight: .semibold))

            Picker("Refresh interval", selection: $settings.refreshInterval) {
                Text("1 second").tag(1)
                Text("2 seconds").tag(2)
                Text("5 seconds").tag(5)
            }
            .pickerStyle(.segmented)

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 380)
    }
}
