//
//  SettingsView.swift
//  FlowTrace — Feature/Settings
//
//  The Settings window's shell: `SettingsRootView` (a drawn tab bar above
//  the selected pane) plus the tab / metrics / dispatcher types it needs.
//  `AppDelegate` hosts that view in a plain `NSWindow` and resizes the
//  window per pane. The panes live in their own files (`Settings*Pane.swift`)
//  and share components from `SettingsComponents.swift`.
//
//  The macOS 13+ `Settings { }` scene is unavailable because the deployment
//  target is 11.0, and the tab bar is drawn here rather than left to
//  `NSTabViewController`'s toolbar tabs — see `SettingsRootView` for why.
//
//  Component policy
//  ----------------
//  Platform controls wherever the system accent is acceptable: `Toggle`
//  (switch), `Stepper`, `NSAlert`. Where a *custom* accent has to show, the
//  control is hand-built, because the AppKit-drawn alternative reads the
//  system accent from app-wide semantic colours that no public API can
//  override (see Feature/Appearance/AccentControls.swift):
//
//    drop-downs        → `AccentPicker` (hover/selection in the accent)
//    text fields       → `AccentTextField` (accent ring + accent text
//                        selection; native editing kept)
//    date / time       → `AccentDateField` (shared, in AccentControls.swift)
//                        and `AccentTimeField` (HH:MM:SS, in
//                        SettingsComponents.swift), replacing
//                        `DatePicker` / `NSDatePicker`
//
//  Hand-built means giving up some platform behaviour — NSMenu keyboard
//  navigation, the system focus ring and text-selection colour, the system
//  calendar popup. That is the accepted cost of a custom accent; "Follow
//  system" avoids all of it.
//
//  No hard-coded point sizes for text: rows use semantic text styles, so
//  labels follow the user's accessibility text-size settings, and the control
//  column has one shared width so the pane reads as a native settings table.
//
//  All user-visible strings go through `Loc.l(_:)` (localization), and the
//  "Language" picker writes `SettingsStore.languageOverride`, which
//  `LocalizationManager` reads to repaint the app in the chosen locale. Each
//  pane observes that manager so its labels re-read after a language change —
//  the observation itself is what drives the re-render, so the property is not
//  otherwise referenced.
//

import SwiftUI
import AppKit

// MARK: - Tabs

/// One pane of the settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, quota, alerts, storage, about

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .general: return "General"
        case .quota:   return "Quota"
        case .alerts:  return "Alerts"
        case .storage: return "Storage"
        case .about:   return "About"
        }
    }

    /// Tab-bar glyph. Sized with `.font` by the tab button, per the AGENTS.md
    /// rule on SF Symbols.
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .quota:   return "gauge"
        case .alerts:  return "bell"
        case .storage: return "externaldrive"
        case .about:   return "info.circle"
        }
    }

    /// Natural pane height. The window resizes to this when the user picks
    /// a tab — native preferences windows are sized per pane — and it is
    /// generously set so the tallest state of each pane (conditional rows
    /// expanded) needs no scrolling.
    var contentHeight: CGFloat {
        switch self {
        case .general: return 460
        case .quota:   return 300
        case .alerts:  return 340
        case .storage: return 400
        case .about:   return 360
        }
    }
}

/// Shared pane metrics: one source for the pane width and control column
/// keeps the five panes aligned with each other.
enum SettingsMetrics {
    static let width: CGFloat = 480
    static let padding: CGFloat = 20
    /// Height of the drawn tab bar, which the window adds on top of
    /// `SettingsTab.contentHeight`. Sized to the bar's natural height — the
    /// tab button (icon line + label line + its vertical padding) plus the
    /// bar's own vertical padding — so the pane below gets all of
    /// `contentHeight` instead of being squeezed by the difference.
    static let tabBarHeight: CGFloat = 66
    /// Width of the trailing control column. Every row's control is framed
    /// to this, so switches, pickers and fields line up down the pane.
    static let controlWidth: CGFloat = 200
}

/// Builds the pane for a tab. Keeping pane construction inside this module
/// means the window assembly in `AppDelegate` only deals with `SettingsTab`.
enum SettingsPanes {
    @ViewBuilder
    static func view(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: SettingsGeneralPane(settings: SettingsStore.shared)
        case .quota:   SettingsQuotaPane(settings: SettingsStore.shared)
        case .alerts:  SettingsAlertsPane(settings: SettingsStore.shared)
        case .storage: SettingsStoragePane(settings: SettingsStore.shared)
        case .about:   SettingsAboutPane()
        }
    }
}

/// Which pane the settings window is showing. Owned by `AppDelegate` so the
/// window can be resized when the selection changes.
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The settings window's content: a tab bar above the selected pane.
///
/// The tab bar is drawn here instead of using `NSTabViewController`'s toolbar
/// tabs (which this window used to do). AppKit's preference-toolbar selection
/// tints the selected item's **icon and label** with the system accent, and
/// that styling has no override — so the selected tab changed colour. Drawing
/// it keeps both in the label colour in either appearance and shows selection
/// as a neutral highlight only, which is what the window should look like.
///
/// Dropping the tab controller also removes three AppKit traps this window kept
/// hitting: the child view-controller title rewriting the window title, item
/// images having to be re-assigned, and toolbar labels needing a manual locale
/// refresh (a SwiftUI `Text` re-reads `Loc.l` on its own).
struct SettingsRootView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: selection)
            Divider()
            SettingsPanes.view(for: selection.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsMetrics.width)
    }
}

/// Icon-over-label buttons, the shape a preferences window normally uses.
///
/// Localisation is deliberately *not* observed here: the bar carries no text
/// of its own, and an observation at this level would only re-run this body,
/// which re-creates each button with identical inputs — `SettingsTabButton`
/// observes the manager itself for that reason.
private struct SettingsTabBar: View {
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        HStack(spacing: 12) {
            // Flexible spacers on both sides centre the cluster inside whatever
            // width the window gives the bar.
            Spacer(minLength: 0)
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, isSelected: tab == selection.tab) {
                    commitPendingEdit()
                    selection.tab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Commit whatever the focused text field is holding, before its pane goes
    /// away.
    ///
    /// Switching tabs rebuilds the pane's views, so a field that is mid-edit is
    /// torn down without AppKit reporting end-of-editing and the typed value is
    /// dropped. A SwiftUI `Button` never becomes first responder on a click, so
    /// clicking the tab leaves the field focused — resigning it here, while the
    /// old pane is still alive, routes the value through the ordinary
    /// end-editing path instead.
    ///
    /// Committing from `AccentTextField.dismantleNSView` instead is not an
    /// option: that runs inside SwiftUI's teardown and aborts the process on an
    /// exclusivity violation.
    private func commitPendingEdit() {
        _ = NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let onTap: () -> Void

    // The tab label is `Loc.l(tab.labelKey)`, resolved inside this view's
    // `body`. Nothing in this view's own inputs (`tab`, `isSelected`,
    // `onTap`) changes when the language does, so observing the language
    // manager *here* — not in `SettingsTabBar` — is what makes the label
    // re-resolve. See the note on `SettingsRow` for the full mechanism.
    @ObservedObject private var l10n = LocalizationManager.shared
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 18))
                Text(Loc.l(tab.labelKey))
                    .font(.caption)
            }
            // The button hugs its content rather than taking a fixed width, so
            // the selection / hover pill has the same extent as the icon and
            // label. With a fixed width (74pt) the pill was ~27pt wider than its
            // content on each side, and since only the *selected* tab shows one,
            // the row's visible centre sat half of that to the left of the
            // window's centre — it read as the whole bar being off-centre.
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Selection is shown by the background alone: the icon and label
            // keep the label colour in every state, so nothing "changes colour"
            // when a tab is picked.
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? Color.primary.opacity(0.12)
                          : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .foregroundColor(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
