//
//  SettingsGeneralPane.swift
//  FlowTrace — Feature/Settings
//
//  The General pane: launch at login, menu-bar visibility, sort mode,
//  language, appearance and the accent-colour controls.
//

import SwiftUI

// MARK: - 通用

struct SettingsGeneralPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var accent = AccentColorManager.shared

    // Language options. `nil` = follow the system; otherwise a locale id.
    // Only "Follow system" is translated — the language names are shown in
    // their own script so the list never re-labels itself.
    private let languageOptions: [(label: String, value: String?)] = [
        ("Follow system",  nil),
        ("简体中文",        "zh-Hans"),
        ("English",        "en"),
        ("繁體中文",        "zh-Hant"),
        ("Español",        "es"),
        ("Português",      "pt-BR"),
        ("Français",       "fr"),
        ("Deutsch",        "de"),
        ("Italiano",       "it"),
        ("Русский",        "ru"),
        ("日本語",          "ja"),
        ("한국어",          "ko"),
        ("Tiếng Việt",     "vi"),
        ("हिन्दी",          "hi"),
        ("বাংলা",          "bn"),
        ("اردو",           "ur"),
        ("ਪੰਜਾਬੀ",         "pa"),
        ("मराठी",          "mr"),
        ("தமிழ்",          "ta"),
        ("Basa Jawa",      "jv"),
        ("العربية",        "ar"),
        ("فارسی",          "fa"),
    ]

    private let sortModeOptions: [(label: String, raw: String)] = [
        ("Name",     "name"),
        ("Live ↓",   "download"),
        ("Live ↑",   "upload"),
        ("Today ↓",  "cumulativeDownload"),
        ("Today ↑",  "cumulativeUpload"),
        ("Today ∑",  "cumulativeTotal"),
    ]

    var body: some View {
        SettingsPane {
            SettingsRow(label: "Launch at login") {
                SettingsSwitch(isOn: $settings.launchAtLogin)
            }

            Divider()

            // Menu-bar visibility. A section caption names the group so the
            // row labels below can stay short ("Download ↙", not "Show
            // download in the menu bar ↙"). The rows sit one size below the
            // caption and indent under it — a Group-level font, which the
            // (font-unspecified) row labels inherit; the switch controls and
            // the footnote note are untouched by it.
            SettingsSectionTitle(text: "Menu bar display")
            Group {
                // The logo is the never-empty fallback: while every other
                // segment is off it is forced on and the toggle is disabled —
                // the user cannot switch off the last thing that identifies
                // the item.
                let forceLogo = !(settings.showDownloadInStatusBar
                    || settings.showUploadInStatusBar
                    || settings.showTodayInMenuBar
                    || settings.showPeriodInMenuBar)
                SettingsRow(label: "Logo") {
                    SettingsSwitch(isOn: Binding(
                        get: { forceLogo ? true : settings.showLogoInMenuBar },
                        set: { settings.showLogoInMenuBar = $0 }
                    ))
                    .disabled(forceLogo)
                }
                SettingsRow(label: "Download ↙") {
                    SettingsSwitch(isOn: $settings.showDownloadInStatusBar)
                }
                SettingsRow(label: "Upload ↗") {
                    SettingsSwitch(isOn: $settings.showUploadInStatusBar)
                }
                SettingsRow(label: "Today total D") {
                    SettingsSwitch(isOn: $settings.showTodayInMenuBar)
                }
                SettingsRow(label: "Period total P") {
                    SettingsSwitch(isOn: $settings.showPeriodInMenuBar)
                }
                // P is not always "this month": its window is the quota period.
                // That used to live in a code comment only — surface it, because
                // the caption above no longer spells out what D/P mean.
                SettingsNote(text: "Period total P follows the quota period in Settings ▸ Quota.")
            }
            .font(.subheadline)
            .padding(.leading, 12)

            Divider()

            // Popover visibility: which modules the popover window renders.
            // The default sort lives here too — it configures the same
            // window's process list. Row labels reuse the on-canvas keys
            // ("last 2 min" / "today peak" / "Today ∑" / "Open history
            // statistics") so each switch names exactly what it toggles.
            SettingsSectionTitle(text: "Popover display")
            Group {
                SettingsRow(label: "Process default sort") {
                    AccentPicker(
                        options: sortModeOptions.map { (label: Loc.l($0.label), value: $0.raw) },
                        selection: $settings.defaultSortModeRaw
                    )
                }
                SettingsRow(label: "Process list") {
                    SettingsSwitch(isOn: $settings.showProcessListInPopover)
                }
                SettingsRow(label: "Network interfaces") {
                    SettingsSwitch(isOn: $settings.showInterfacesInPopover)
                }
                SettingsRow(label: "Last 2 min") {
                    SettingsSwitch(isOn: $settings.showSparklineInPopover)
                }
                SettingsRow(label: "Today peak") {
                    SettingsSwitch(isOn: $settings.showTodayPeakInPopover)
                }
                SettingsRow(label: "Today ∑") {
                    SettingsSwitch(isOn: $settings.showTodayTotalInPopover)
                }
                SettingsRow(label: "Open history statistics") {
                    SettingsSwitch(isOn: $settings.showHistoryEntryInPopover)
                }
            }
            .font(.subheadline)
            .padding(.leading, 12)

            Divider()

            SettingsRow(label: "Language") {
                // Self-drawn drop-down so hover/selection use the app accent;
                // SwiftUI re-reads the labels on re-render, so no `.id(locale)`
                // rebuild is needed.
                AccentPicker(
                    options: languageOptions.map {
                        (label: $0.value == nil ? Loc.l($0.label) : $0.label, value: $0.value)
                    },
                    selection: $settings.languageOverride
                )
            }

            // Overall appearance: system / light / dark.
            SettingsRow(label: "Appearance") {
                AccentPicker(
                    options: AppearanceMode.allCases.map {
                        (label: Loc.l($0.labelKey), value: $0.rawValue)
                    },
                    selection: $settings.appearanceRaw
                )
            }

            SettingsRow(label: "Accent color") {
                AccentPicker(
                    options: AccentSource.allCases.map {
                        (label: Loc.l($0.labelKey), value: $0)
                    },
                    selection: accentSourceBinding
                )
            }

            accentDetailRow
        }
    }

    /// The custom-colour controls, on their own row under the mode picker.
    /// Shown in every mode but disabled while following the system accent,
    /// where there is nothing to edit (native settings grey out controls
    /// that do not apply rather than hiding them, which also keeps the pane
    /// height — and therefore the window — stable).
    private var accentDetailRow: some View {
        HStack(spacing: 8) {
            // Always-visible confirmation of the current colour: the native
            // picker's own swatch only shows on hover.
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.customColor)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            ColorPicker("", selection: accentColorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 60)
            AccentHexField(hex: accent.customHex) { accent.setCustomHex($0) }
            Spacer(minLength: 12)
            Button(Loc.l("Reset")) {
                accent.resetToDefault()
            }
            .buttonStyle(.borderless)
            .disabled(!canResetAccent)
        }
        .disabled(accent.source != .custom)
        .animation(.easeInOut(duration: 0.15), value: accent.customHex)
    }

    /// Reset is meaningful only when the choice is not already the
    /// out-of-box one (custom + #00CFFF).
    private var canResetAccent: Bool {
        accent.source != AccentColorManager.defaultSource
            || accent.customHex != AccentColorManager.defaultHex
    }

    /// Mode picker binding — `AccentColorManager.source` is private(set) to
    /// keep the invariant that only validated values reach storage.
    private var accentSourceBinding: Binding<AccentSource> {
        Binding(get: { accent.source }, set: { accent.setSource($0) })
    }

    /// Colour picker binding. Alpha never round-trips: the picker is
    /// configured without opacity and the setter strips it anyway.
    private var accentColorBinding: Binding<Color> {
        Binding(get: { accent.customColor }, set: { accent.setCustomColor($0) })
    }
}
