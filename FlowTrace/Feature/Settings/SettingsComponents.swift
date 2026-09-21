//
//  SettingsComponents.swift
//  FlowTrace — Feature/Settings
//
//  The building blocks every settings pane is assembled from: pane chrome,
//  rows, switches, notes, and the hand-built numeric / time fields.
//

import SwiftUI
import AppKit

// MARK: - Shared row layout

/// One settings row: localised label, flexible gap, trailing control — the
/// standard macOS preferences row. The control column is a fixed width so
/// the controls form a column down the pane.
///
/// **The row observes the language manager itself.** `Loc.l(label)` is
/// resolved inside `body`, but `label` is a plain `String` — a *key* like
/// "Launch at login", identical in both languages. When the language changes,
/// the pane above re-runs its `body` and re-creates this row with byte-for-byte
/// the same stored properties, so SwiftUI has nothing to compare against and
/// keeps the already-resolved `Text` from the previous language. The
/// observation has to sit on the view that *renders* the string, which is
/// here; the pane-level observation alone only re-runs the pane's own body.
/// Symptom without it: the first language change looked fine, later ones left
/// these labels in the old language until some unrelated state (a tab switch,
/// a hover) forced the row to rebuild.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Loc.l(label))
            Spacer(minLength: 12)
            control
                .frame(width: SettingsMetrics.controlWidth, alignment: .trailing)
        }
    }
}

/// A settings switch with no inline label: the row's label is the visible
/// one and sits on the left, which is the macOS preferences layout.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// Secondary explanatory line under a row: system footnote style and the
/// secondary label colour, wrapping to as many lines as it needs.
struct SettingsNote: View {
    let text: String

    // Same reason as `SettingsRow`: the key is language-independent, so the
    // observation has to be on the view that resolves it.
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        Text(Loc.l(text))
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Common pane chrome: standard padding, top-aligned, width driven by the
/// window (so the pane stretches if the user widens it) with a minimum
/// matching `SettingsMetrics.width`.
///
/// This is also the settings window's accent application point. Each pane is
/// the root of its own `NSHostingController` (the tab controller hosts one
/// per tab), so the scope has to be applied per pane rather than once on a
/// shared parent view — without it the panes fall back to the system accent
/// and a custom colour never reaches them.
struct SettingsPane<Content: View>: View {
    @ObservedObject private var accent = AccentColorManager.shared
    // The pane observes the language manager so any `Loc.l(_:)` written
    // directly in a pane's own body (storage's button titles and range
    // labels, the about pane's paragraphs) re-resolves on a language change.
    //
    // This deliberately does *not* cover strings that a child view resolves
    // from one of its own stored properties — a row's label key, a note's
    // text key, a tab's label key. Re-running this body re-creates those
    // children with identical inputs, so SwiftUI keeps their cached
    // `Text`; each of them observes the manager itself instead
    // (`SettingsRow`, `SettingsNote`, `SettingsTabButton`).
    @ObservedObject private var l10n = LocalizationManager.shared
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(SettingsMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appAccentScope(accent.accent)
        .animation(.easeInOut(duration: 0.2), value: accent.animationIdentity)
    }
}

// MARK: - Shared field components

/// A numeric setting: accent-ringed text field plus the platform stepper for
/// nudges.
///
/// The field is `AccentTextField`, so its ring is the app accent (the system
/// ring cannot be retinted). Parsing and clamping happen on commit, which
/// keeps the models (quota limit, alert multipliers, retention) inside their
/// documented bounds no matter what is typed.
struct EditableNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 6) {
            AccentTextField(
                text: "\(value)",
                font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                alignment: .right,
                onCommit: commit,
                isFocused: $isFocused
            )
            .frame(width: 72)
            .accentFieldChrome(isFocused: isFocused)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }

    /// Clamp into `range`; non-numeric input is rejected, which makes the
    /// field restore the current value.
    private func commit(_ typed: String) -> Bool {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard let parsed = Int(trimmed) else { return false }
        value = min(max(parsed, range.lowerBound), range.upperBound)
        return true
    }
}

/// Seconds-precision time-of-day field (HH:MM:SS).
///
/// Hand-built so the ring and the value follow the app accent: `NSDatePicker`
/// draws its selected segment with the system accent and exposes no tint API.
/// The field accepts "HH", "HH:MM" or "HH:MM:SS" and rejects out-of-range
/// input; the platform stepper nudges it a minute at a time.
struct AccentTimeField: View {
    @Binding var secondsOfDay: Int

    @State private var isFocused = false

    private static let maxSeconds = 24 * 3600 - 1

    var body: some View {
        HStack(spacing: 6) {
            AccentTextField(
                text: Self.label(for: secondsOfDay),
                placeholder: "HH:MM:SS",
                font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                alignment: .center,
                onCommit: commit,
                isFocused: $isFocused
            )
            .frame(width: 78)
            .accentFieldChrome(isFocused: isFocused)
            Stepper("", value: $secondsOfDay, in: 0...Self.maxSeconds, step: 60)
                .labelsHidden()
        }
    }

    private static func label(for seconds: Int) -> String {
        let clamped = max(0, min(seconds, maxSeconds))
        return String(format: "%02d:%02d:%02d", clamped / 3600, (clamped % 3600) / 60, clamped % 60)
    }

    /// Parses "H", "H:M" or "H:M:S" into seconds since local midnight.
    private func commit(_ typed: String) -> Bool {
        let parts = typed.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...3).contains(parts.count) else { return false }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return false }
            values.append(value)
        }
        let hours = values[0]
        let minutes = values.count > 1 ? values[1] : 0
        let seconds = values.count > 2 ? values[2] : 0
        guard hours < 24, minutes < 60, seconds < 60 else { return false }
        secondsOfDay = hours * 3600 + minutes * 60 + seconds
        return true
    }
}
