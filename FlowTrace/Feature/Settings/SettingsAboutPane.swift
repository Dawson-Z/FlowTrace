//
//  SettingsAboutPane.swift
//  FlowTrace — Feature/Settings
//
//  The About pane: app identity, version, and the intro / statistics /
//  privacy / tech-note paragraphs.
//

import SwiftUI
import AppKit

// MARK: - 关于

struct SettingsAboutPane: View {
    @ObservedObject private var l10n = LocalizationManager.shared

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPane {
            // App identity
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // The app's name in the chosen language (流探 in Chinese),
                    // matching the popover header and the Finder — not a
                    // hard-coded product name.
                    Text(Loc.appDisplayName)
                        .font(.headline)
                    Text(String(format: Loc.l("Version %@"), versionText))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // The fork's own source repository. A plain Link opens the
                    // browser only on click — the app itself still makes no
                    // network requests (the AGENTS.md rule); "GitHub" is a
                    // proper noun and needs no localization.
                    Link(destination: URL(string: "https://github.com/Dawson-Z/FlowTrace")!) {
                        HStack(spacing: 3) {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                            Text("GitHub")
                                .font(.caption)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            Divider()

            Text(Loc.l("About intro"))
                .fixedSize(horizontal: false, vertical: true)

            Text(Loc.l("About statistics"))
                .fixedSize(horizontal: false, vertical: true)

            Text(Loc.l("About privacy"))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(Loc.l("About tech note"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
