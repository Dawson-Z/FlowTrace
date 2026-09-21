//
//  AccentColor.swift
//  FlowTrace — Feature/Appearance
//
//  Accent-colour subsystem, rewritten from scratch (2026-09).
//
//  One preference, two sources:
//    .system — follow the accent the user picked in macOS System Settings
//    .custom — a colour picked inside this app (brand default #00CFFF)
//
//  New installs start in `.custom` mode with #00CFFF, so the brand tint
//  is visible out of the box and "Follow system" is an explicit opt-in.
//
//  Architecture
//  ------------
//  AccentColorManager   Singleton ObservableObject; the single source of
//                       truth. Owns persistence, hex validation and a
//                       live watch on the *system* accent (so flipping
//                       the accent in System Settings repaints the app
//                       without a relaunch).
//  View.appAccentScope  The one application point per window root. It
//                       (a) tints every tint-aware SwiftUI control in the
//                       subtree and (b) publishes the colour as the
//                       `\.appAccent` environment value, which is what
//                       the hand-drawn surfaces read (sort underlines,
//                       heatmap cells, legend swatches).
//  AccentHexField       Free-form "#RRGGBB" text input with commit-time
//                       validation and visual revert on bad input.
//
//  One application point per window root
//  -------------------------------------
//  `.appAccentScope(_:)` must be applied at *every* root that SwiftUI
//  renders independently — the popover, the history window, and each
//  settings pane (the tab controller hosts one `NSHostingController` per
//  tab, so there is no shared parent to tint). A root without the scope
//  silently falls back to the macOS system accent: that is exactly how a
//  custom colour failed to reach the settings pane's switches.
//
//  `.tint` does reach a native `Toggle(.switch)` on macOS 12+, including
//  when applied to an ancestor rather than the control itself (verified by
//  offscreen render on macOS 15.7), so no hand-rolled control is needed.
//
//  Storage (UserDefaults.standard, so `defaults read local.FlowTrace`
//  works from the CLI):
//    ft.accent.source = "system" | "custom"
//    ft.accent.hex    = "#RRGGBB" (canonical, uppercase, validated)
//
//  Malformed stored values (wrong shape, non-hex, wrong length) fall back
//  to the brand default instead of crashing or rendering invisible.
//
//  Compatibility
//  -------------
//  Deployment target is macOS 11: `.tint` is applied on 12+ (the SDK no
//  longer repaints `.accentColor` live there) with `.accentColor` as the
//  11 fallback. Every colour conversion goes through sRGB so the picker,
//  the hex field and AppKit views always agree on the value.
//
//  Threading: the manager is main-thread-only by convention — it is only
//  touched from SwiftUI bodies and the settings UI, and the system-accent
//  watch is delivered on the main queue.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Source

/// Where the accent colour comes from. Persisted as a String raw value
/// under `ft.accent.source`.
enum AccentSource: String, CaseIterable, Identifiable {
    case system
    case custom

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .system: return "Follow system"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Manager

/// Single source of truth for the app-wide accent colour. Observed by the
/// three window roots (popover, settings, history); everything below them
/// receives the colour through `\.appAccent`.
final class AccentColorManager: ObservableObject {

    static let shared = AccentColorManager()

    /// Brand default — also the recovery value for malformed stored data.
    static let defaultHex = "#00CFFF"
    /// New installs start in custom mode (see the header comment).
    static let defaultSource: AccentSource = .custom

    /// Where the accent comes from.
    @Published private(set) var source: AccentSource

    /// The custom colour, canonical "#RRGGBB". Only read in `.custom`.
    @Published private(set) var customHex: String

    /// Bumped when the *system* accent may have changed, so every observed
    /// subtree re-renders and re-resolves the dynamic control-accent colour.
    @Published private var systemAccentRevision = 0

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var systemAccentObserver: AnyObject?

    private enum K {
        static let source = "ft.accent.source"
        static let hex = "ft.accent.hex"
        /// Keys written by earlier implementations. Removed once on init so
        /// dead preferences don't linger in `defaults read` output.
        static let legacy = ["accentMode", "accentRGBA", "accentFollowSystem"]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for key in K.legacy { defaults.removeObject(forKey: key) }

        if let raw = defaults.string(forKey: K.source),
           let parsed = AccentSource(rawValue: raw) {
            source = parsed
        } else {
            source = Self.defaultSource
        }

        // Validation on load: anything that doesn't parse as a hex colour
        // silently falls back to the brand default.
        if let stored = defaults.string(forKey: K.hex) {
            customHex = Self.normalizedHex(fromRaw: stored) ?? Self.defaultHex
        } else {
            customHex = Self.defaultHex
        }

        // Persist on every user-driven change. `dropFirst()` skips the
        // seed emission from `@Published` initialisation.
        $source.dropFirst()
            .sink { [weak self] in self?.defaults.set($0.rawValue, forKey: K.source) }
            .store(in: &cancellables)
        $customHex.dropFirst()
            .sink { [weak self] in self?.defaults.set($0, forKey: K.hex) }
            .store(in: &cancellables)

        // Live-follow the macOS accent. System Settings posts this
        // distributed notification when the user picks a new highlight
        // colour; bumping the revision republishes the manager, which
        // makes every observed root re-read `accent`.
        systemAccentObserver = DistributedNotificationCenter.default()
            .addObserver(forName: .appleColorPreferencesChanged,
                         object: nil, queue: .main) { [weak self] _ in
                self?.systemAccentRevision &+= 1
            }
    }

    deinit {
        if let systemAccentObserver {
            DistributedNotificationCenter.default().removeObserver(systemAccentObserver)
        }
    }

    // MARK: Resolved colour

    /// The colour every surface should render right now.
    var accent: Color {
        switch source {
        case .custom:
            return Self.color(fromHex: customHex) ?? Self.color(fromHex: Self.defaultHex)!
        case .system:
            // Revision dependency: the distributed-notification bump makes
            // every observed root re-render, which re-resolves the colour
            // below (a snapshot never updates on its own).
            _ = systemAccentRevision
            return Self.systemAccentColor
        }
    }

    /// The macOS control accent resolved to a *concrete* sRGB colour.
    ///
    /// Wrapping the dynamic `NSColor.controlAccentColor` directly
    /// (`Color(NSColor)`) mis-resolves inside SwiftUI on some bridged
    /// surfaces — observed as pickers and menus rendering **red** while
    /// the system accent is blue — so the dynamic colour is resolved to
    /// concrete components here, in the current appearance. System-accent
    /// changes still repaint live via `systemAccentRevision`.
    static var systemAccentColor: Color {
        let ns = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        return Color(
            red: channel(ns?.redComponent),
            green: channel(ns?.greenComponent),
            blue: channel(ns?.blueComponent)
        )
    }

    /// The stored custom colour, independent of the current source (the
    /// settings row needs it even while flipping the picker).
    var customColor: Color {
        Self.color(fromHex: customHex) ?? Self.color(fromHex: Self.defaultHex)!
    }

    /// Stable identity of the current choice — the animation trigger at the
    /// window roots. Constant in `.system` mode, so system-accent revision
    /// bumps don't cross-fade the whole UI for no visual change.
    var animationIdentity: String {
        source.rawValue + customHex
    }

    // MARK: Mutations (settings UI only)

    func setSource(_ newSource: AccentSource) {
        source = newSource
    }

    /// Apply a ColorPicker selection. Normalised through sRGB; alpha is
    /// stripped because the picker is configured without opacity support.
    func setCustomColor(_ color: Color) {
        customHex = Self.hex(fromColor: color)
    }

    /// Validate + apply a typed hex string. Returns false (changing nothing)
    /// when the input is not a 3- or 6-digit hex colour — the field shows
    /// the failure, the stored value stays untouched.
    @discardableResult
    func setCustomHex(_ raw: String) -> Bool {
        guard let hex = Self.normalizedHex(fromRaw: raw) else { return false }
        customHex = hex
        return true
    }

    /// Back to the out-of-box choice: custom mode + brand colour.
    func resetToDefault() {
        source = .custom
        customHex = Self.defaultHex
    }

    // MARK: Hex parsing — the only place colour<->text conversion lives

    /// Accepts "#00CFFF", "00CFFF", "00cfff" and the 3-digit shorthand
    /// ("0cf"). Returns the canonical "#RRGGBB" form, or nil when the input
    /// is not a hex colour.
    static func normalizedHex(fromRaw raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.reduce(into: "") { $0.append($1); $0.append($1) }
        }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s
    }

    /// Canonical colour for a "#RRGGBB" string; nil on malformed input.
    static func color(fromHex hex: String) -> Color? {
        guard let normalized = normalizedHex(fromRaw: hex) else { return nil }
        let value = Int(normalized.dropFirst(), radix: 16)!
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// Canonical "#RRGGBB" for any SwiftUI colour, normalised through sRGB
    /// so picker, text field and AppKit views agree. Non-finite components
    /// clamp to 0 instead of producing garbage.
    static func hex(fromColor color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        return String(format: "#%02X%02X%02X",
                      component(ns?.redComponent),
                      component(ns?.greenComponent),
                      component(ns?.blueComponent))
    }

    /// Black or white, whichever reads better on `color`.
    ///
    /// The accent is user-chosen, so a fixed label colour would make some
    /// choices unreadable — e.g. white on the default #00CFFF is fine, white
    /// on a pale yellow is not. Used for text drawn *on* an accent fill.
    static func readableForeground(on color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        let r = channel(ns?.redComponent)
        let g = channel(ns?.greenComponent)
        let b = channel(ns?.blueComponent)
        // Rec. 709 relative luminance.
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .black : .white
    }

    private static func component(_ value: CGFloat?) -> Int {
        Int((channel(value) * 255).rounded())
    }

    /// One sRGB channel: nil / non-finite / out-of-range values clamp into
    /// 0...1 instead of producing garbage colour components.
    private static func channel(_ value: CGFloat?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return Double(min(max(value, 0), 1))
    }
}

extension Notification.Name {
    /// Posted by macOS when the user changes the highlight colour in
    /// System Settings. Distributed (cross-process) — delivered to this
    /// app on the main queue via the manager's observer.
    static let appleColorPreferencesChanged =
        Notification.Name("AppleColorPreferencesChangedNotification")
}

// MARK: - SwiftUI integration

private struct AppAccentEnvironmentKey: EnvironmentKey {
    static let defaultValue = AccentColorManager.systemAccentColor
}

extension EnvironmentValues {
    /// The accent colour to render right now. Set at every window root by
    /// `.appAccentScope(_:)`; descendants read it with
    /// `@Environment(\.appAccent)` rather than poking the manager, so a
    /// colour change invalidates exactly the views that draw it.
    var appAccent: Color {
        get { self[AppAccentEnvironmentKey.self] }
        set { self[AppAccentEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// The one application point per window root. Tints every SwiftUI
    /// control in the subtree *and* publishes the colour to `\.appAccent`
    /// for hand-drawn fills and AppKit-bridged controls.
    ///
    /// The root must observe `AccentColorManager.shared` so a mode flip,
    /// colour change or system-accent change re-runs this modifier.
    ///
    /// macOS 12+ applies `.tint` (the supported live-updating modifier);
    /// macOS 11 falls back to `.accentColor`.
    func appAccentScope(_ accent: Color) -> some View {
        environment(\.appAccent, accent)
            .modifier(AccentTintModifier(color: accent))
    }
}

/// See `View.appAccentScope(_:)`.
struct AccentTintModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.tint(color)
        } else {
            content.accentColor(color)
        }
    }
}

// MARK: - AccentHexField

/// Free-form "#RRGGBB" input for the settings accent row.
///
/// Built on `AccentTextField`, so the ring around the field is the app accent
/// (the system focus ring and text-selection colour cannot be retinted — see
/// AccentControls.swift). Typing is unrestricted; the value is validated only
/// on commit (Return or focus loss): a valid 3/6-digit hex applies and the
/// field snaps to its canonical form, an invalid one is flagged with a red
/// ring and reverts. External changes (colour-picker drag, Reset) refresh the
/// text whenever the field is not being edited.
struct AccentHexField: View {
    /// Current canonical value from the manager.
    let hex: String
    /// Commit hook; returns false for invalid input.
    let onCommit: (String) -> Bool

    @State private var isFocused = false
    @State private var invalidInput = false

    var body: some View {
        AccentTextField(
            text: hex,
            placeholder: AccentColorManager.defaultHex,
            font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            onCommit: { typed in
                let accepted = onCommit(typed)
                invalidInput = !accepted
                return accepted
            },
            isFocused: $isFocused
        )
        .frame(width: 78)
        // Error feedback: the ring is the accent colour normally, red while
        // the last commit was rejected.
        .accentFieldChrome(isFocused: isFocused)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.red, lineWidth: invalidInput ? 2 : 0)
        )
        // Editing again clears the previous rejection, so the red ring never
        // sits on text that is in fact valid.
        .onChange(of: isFocused) { focused in
            if focused { invalidInput = false }
        }
        .animation(.easeInOut(duration: 0.12), value: invalidInput)
        .accessibilityLabel(Loc.l("Accent color"))
    }
}
