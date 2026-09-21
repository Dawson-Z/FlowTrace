# AGENTS.md

Guidance for AI agents — and humans — working in this repository.

## This repository is private, local-only

This is a research fork of [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac), kept on a developer machine for local experimentation. It is **not** published, not on Homebrew, not on GitHub Releases, and not on the Mac App Store.

Because the fork is private, the "never commit credentials / paths / session logs" rule of the upstream AGENTS.md is still good hygiene but is no longer load-bearing. The bigger concern here is keeping the fork cleanly separated from the upstream so that ideas flow one way only: **out of the upstream, into this fork** — never the reverse.

- **Do not** push this repository anywhere, **do not** open a PR against the upstream.
- **Do not** copy private source, internal design documents, or commercial-only logic from any other product into this tree.
- **Do not** re-enable the upstream's notarisation / Developer ID signing / Homebrew Cask pipeline. The Release scheme in `project.yml` keeps the hardened runtime but otherwise leaves signing ad-hoc.

## What this project is

FlowTrace is a local-only research build of iTraffic. It inherits the upstream's core idea — small, open-style, per-process macOS menu-bar network monitor driving `/usr/bin/nettop` — and adds local-only experiments on top: process search, in-memory traffic history, interface-aware sampling, and similar features that can be done in user space without NetworkExtension or system entitlements.

The experimental features are **not** the same as anything shipped by any other product from the same author. They are designed from Apple public documentation and the upstream's user-state code, full stop.

## Layout

```
FlowTrace/                         fork-specific experiments
  Feature/Appearance/                accent-colour subsystem + hand-built controls
  Feature/History/                   ring buffer, SQLite persistence, history
                                     window (app usage / heatmap / alerts), CSV
  Feature/Interface/                 per-interface-category sampling + overview
  Feature/Localization/              runtime locale resolver (Loc.l)
  Feature/Logging/                   os.Logger + file sink (Log.* helpers)
  Feature/Search/                    process search
  Feature/Settings/                  SettingsStore, settings window, retention,
                                     data cleaner, launch at login
  Feature/Usage/                     period totals, quota alerts, process alerts
FlowTraceForMac/                   upstream-derived app sources (several touched
                                   by this fork — see "Active experiments")
  Service/NettopRunner.swift       drives /usr/bin/nettop
  Network.swift                    parses frames, feeds the models
  Model/                           ObservableObjects backing the two surfaces
  ContentView.swift                popover: header + process list
  StatusBarView.swift              menu-bar rates
docs/ARCHITECTURE.md               architecture + per-file reference
project.yml                        XcodeGen source of truth
changelog/<version>.md             release notes for this fork
```

`FlowTrace.xcodeproj` is generated from `project.yml` and is deliberately **not** committed — `.gitignore` says "never commit the rendered Xcode project". Edit the YAML, run `xcodegen generate`, and commit the YAML only (the project is rebuilt on demand; a fresh clone needs the `xcodegen generate` step above).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Debug
```

Unit tests live in `FlowTraceTests/` and run with `xcodebuild test -project FlowTrace.xcodeproj -scheme FlowTrace -configuration Debug`. They cover the process-list comparator and merge, the quota decision layer, and the two SQLite pipelines (per-app usage, interface heatmap). The last three exercise real dependencies — `SettingsStore(defaults:)` and `QuotaMonitor(settings:aggregator:defaults:)` are injectable, and the persistence tests open a temporary database — so a test run never touches the user's preferences or history.

Note when building locally: Xcode's index store under `~/Library/Developer/Xcode/DerivedData` can be blocked in a sandboxed shell. `-derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO` works around it.

`CODE_SIGN_IDENTITY` is ad-hoc (`-`) in `project.yml` so the project builds with no certificate at all. There is no `scripts/release.sh` analogue here; this fork does not ship.

## Conventions carried from upstream

- **Rates carry their unit in the field name** (`inBytesPerSec`, `totalInBytesPerSec`). `nettop` runs in delta mode over a 1-second sample, so a frame reports bytes moved across the whole window, not a rate. Normalise once in `Network.parser`, at the single point where nettop numbers enter the app, and never re-derive downstream. Issue #28 in the upstream was exactly this: the divide was moved up to the aggregation point, the status bar got it, the process list did not, and every row rendered double for three months.

- **The app makes exactly one network request, and only when clicked.** The upstream's update checker hits the GitHub releases API when the user clicks the version number. We have stripped the upstream's `UpdateChecker.swift` and any network call from this fork because (a) the upstream is a moving target, and (b) the rule — "iTraffic lists the network activity of every process including its own, so a background poll appears to users as unexplained traffic from the one tool whose job is to explain traffic" — applies here too. Any future network work in this fork stays on the same rule.

- **`.help(_:)` is macOS 11+** — exactly the fork's floor, so it needs no annotation here. Anything newer than 11 still gets an `#available` guard rather than a target bump.

- **Size SF Symbols with `.font`, never `.resizable()`** — resizing stretches them into thin sticks at menu-bar sizes. A Unicode glyph in a `Text` avoids the question entirely and carries no availability floor.

## Fork-specific conventions

- **Deployment target is macOS 11.0, not 10.15.** The upstream's 10.15 floor was set when the project shipped to Catalina users who had no other way to see per-process traffic; the fork is local and runs on a Big Sur+ Mac, so the new floor is just "what makes `Logger` and `@StateObject` un-annotated". If the experiment starts needing 13/14-only SwiftUI (`NavigationStack`, `Charts`, …) we will raise again here rather than pepper `@available` through the source.

- **Feature modules live under `FlowTrace/Feature/<Name>/`** and are self-contained: each module owns its view(s), its model, and any pure-function helpers. `FlowTrace/Feature/...` files are added to the Xcode target the same way `FlowTraceForMac/...` files are.

- **Experiments that touch the upstream code must document the touch point** in this AGENTS.md. If you change `ContentView.swift` to host a new search bar, say so here under "Active experiments". Without that note, the next person has to read the diff to know which upstream file is no longer vanilla.

- **No data leaves this machine.** No telemetry, no analytics, no remote update check, no remote catalog fetch. The fork may read `/Applications/...` to extract an icon, but it does not read, parse, or otherwise touch any other product's binaries or private data structures.

## Active experiments

- **Process search bar (0.3.0 milestone 1).** Adds a `SearchFilter` to `ListViewModel` and a `ProcessSearchBar` view at the top of the popover. Touches `ContentView.swift` and `ListViewModel.swift`.
- **In-memory history ring buffer (0.3.0 milestone 1).** Adds `RingBuffer`, `HistoryStore`, and `HistoryView` (a 60-sample sparkline) at the bottom of the popover. Touches `Network.swift` (to push frames into the store) and `ContentView.swift` (to host the view).
- **0.3.0 milestone 2 (refactor-only).** No new features; replaces every `print` with `Logger` (via `FlowTrace/Feature/Logging/AppLogger.swift`), adds a GB tier to `Utils.formatBytes` so the menu bar does not say "1024.0 MB/s", and migrates the @ObservedObject-on-singletons cases to @StateObject. The non-View @ObservedObject cases (on `Network` and `AppDelegate`) are downgraded to plain references because the wrapper is a no-op on a type with no `body`. Touches `AppDelegate.swift`, `Network.swift`, `NettopRunner.swift`, `ContentView.swift`, `StatusBarView.swift`, `Utils.swift`.
- **Accent-colour subsystem (0.3.0 milestone 17).** `FlowTrace/Feature/Appearance/AccentColor.swift` is the whole subsystem (rewritten from scratch in 2026-09): `AccentColorManager` (source of truth; keys `ft.accent.source` / `ft.accent.hex`; new installs default to custom + `#00CFFF`; watches the system accent via the `AppleColorPreferencesChangedNotification` distributed notification), `View.appAccentScope(_:)` (the single application point per window root — applies `.tint`/`.accentColor` and publishes the `\.appAccent` environment value), and `AccentHexField` (validated `#RRGGBB` input). Window roots (`ContentView.swift`, `SettingsView.swift` panes, `HistoryWindowView.swift`) observe the manager and call `.appAccentScope(accent.accent)`; hand-drawn fills (sort underlines, heatmap cells, legend swatches) read `@Environment(\.appAccent)`. Settings UI: mode picker (Follow system / Custom) + swatch + `ColorPicker` + hex field + Reset. Touches `ContentView.swift`, `SettingsView.swift`, `SettingsStore.swift` (no accent keys there), `HistoryWindowView.swift`, `HistoryHeatmapView.swift`.
  **Rule — every independently hosted SwiftUI root needs the scope.** `.tint` does reach native switches, so no hand-rolled control is needed; but the settings window hosts one `NSHostingController` *per tab*, so there is no shared parent to tint. When the panes were split out of the old single `SettingsView`, the scope was dropped and every settings control silently fell back to the system accent. `SettingsPane` now applies it, and any future pane must go through `SettingsPane` (or apply the scope itself).

- **Accent-completeness pass (0.3.0 milestone 19).** `.tint` only reaches what SwiftUI draws. Everything AppKit draws takes its colours from app-wide semantic colours resolved from the *system* accent — measured on this machine: `controlAccentColor` #FFC600, `keyboardFocusIndicatorColor` #FFFF1A, `selectedTextBackgroundColor` #8B7A3F, `selectedContentBackgroundColor` #D19E00 — and none of those can be overridden per app or per control through public API. So where a *custom* accent has to show, the control is hand-built in `FlowTrace/Feature/Appearance/AccentControls.swift`:
  - `AccentTextField` — borderless `NSTextField` with the native focus ring suppressed, wrapped in a ring `.accentFieldChrome(isFocused:)` paints, and with the text selection recoloured by writing the field editor's public `selectedTextAttributes`. AppKit still owns editing (field editor, IME, undo); only ring, bezel and selection colour are ours.
    **Where the tint and the focus flag are triggered from matters.** Writing them in `controlTextDidBeginEditing` looks right and silently does nothing on the path that matters: measured by posting real clicks through the app's event queue, that delegate method is **not called when a click merely puts the caret in the field** — it fires only once text is actually modified. So the highlight kept the platform colour (`#5C7654`, i.e. the *system* accent) and the accent ring stayed in its idle state while the caret sat in the field, even though every programmatic path claimed success. Both are therefore driven from the notifications the field editor itself posts — `NSText.didBeginEditingNotification` and `NSTextView.didChangeSelectionNotification` — filtered by the ownership test `(editor.delegate as? NSTextField) === ourField`. A highlight or a caret cannot appear without a selection change, so those cover every case.
    **Committing is the other half of the same trap.** A field torn down mid-edit never reports end-of-editing: the settings window rebuilds the pane's views on every tab switch, and closing the window tears the whole `NSHostingView` down, so in both cases the field disappears without resigning first responder, `controlTextDidEndEditing` never runs, and whatever was typed was dropped — which is why every text field in Settings looked like it "did not save". Committing has to happen *before* the teardown, while the views are still alive: **`dismantleNSView` must not do it** — it runs inside `NSHostingView.deinit` → `PlatformViewChild.destroy()`, and writing back through a `@Binding` from there trips SwiftUI's exclusivity check (`swift_beginAccess`, reached from `GraphHost.asyncTransaction`) and aborts the process with `EXC_CRASH / SIGABRT`. The live hooks are: `controlTextDidEndEditing` (Return, ordinary focus change), `NSControl.textDidEndEditingNotification` scoped with `object: field`, and `NSWindow.willCloseNotification` matched against `field.window` for the close path. The pane-switch path is covered from the other end — `SettingsTabBar.commitPendingEdit()` resigns the field before flipping `selection.tab`, because a SwiftUI `Button` never takes first responder on a click and so would otherwise leave the field focused as its pane goes away. `updateNSView` likewise tests `field.currentEditor() == nil` instead of a flag set from `controlTextDidBeginEditing` before rewriting `stringValue`: with the flag, the whole click-then-type window counted as "not editing" and a re-render would overwrite the user's first keystrokes.
  - `AccentPicker` — button + popover list, so hover/selection use the accent. Sizes its popover to the button, marks the current value, and picks the label colour from the accent's luminance (`AccentColorManager.readableForeground(on:)`) so pale accents stay readable.
  - `AccentDateField` (shared) — month grid with accent selection/hover/today marker, localized, forward navigation capped at a `latest` date. Used by the settings Storage pane **and all three history-window range filters** (`HistoryWindowView`, `AlertLogView`, `AppUsageView`); `AccentTimeField` stays local to Settings for the HH:MM:SS check-in time.
    **Rule — a hand-built control has to localise itself.** Nothing about it is automatic: `Loc.l(_:)` covers literal strings, but everything the *system* formats (weekday names, month names, date order) comes from a `Locale` that defaults to the system's. `AccentDateField` therefore pins its entire `Calendar` to `LocalizationManager.shared.locale` and sets `.locale` on each `DateFormatter`. The headings and the grid must share **one** calendar: the first column and the column the 1st of the month lands in are both derived from `firstWeekday`, so resolving them separately silently misaligns the grid.
    For any date the user reads, elsewhere in the app, go through `Loc.dateFormatter(template:locale:)` instead of a literal `dateFormat` — a *template* lets the locale decide field order, separators and the 12/24-hour cycle.
    **Hand-rolling that formatter is a trap, and it is the order that bites.** `setLocalizedDateFormatFromTemplate` resolves the template *immediately*, against whatever locale the formatter holds at that moment; setting `.locale` afterwards cannot change a pattern that is already resolved. Calling it first is exactly how the month title came to render "2026年9月" in every language on a Chinese system. `Loc.dateFormatter` sets the locale before expanding, which is why call sites must not rebuild it by hand.
    Machine-facing timestamps remain the deliberate exception: `CSVExporter` and the retention dedup key keep fixed ISO patterns so they stay sortable and parseable anywhere.
  **Rule — never give a bridged AppKit control a fixed width.** `Picker(.segmented)` and `Toggle(.switch)` are AppKit views: they do not wrap or truncate the way a SwiftUI `Text` does, they overdraw whatever sits beside them. Measured needs against the widths the history window used to hard-code: the 4-segment range picker wanted 324 pt in English and 438 pt in French against a fixed 300; each interface toggle wanted 116 pt in English and 162 pt in Russian against a fixed 100. Both are now intrinsic-width (`minWidth` at most) with a `Spacer` absorbing the slack. A SwiftUI `Text` inside a fixed-width column is fine — it wraps — but give it `lineLimit(1)` + `minimumScaleFactor` wherever a taller row would be wrong.
  **Trade-off, accepted deliberately:** this gives up NSMenu keyboard navigation and scrolling, the system focus ring, and the system calendar popup. "Follow system" avoids all of it.
  **Deliberate exception:** the popover's process-search field (`Feature/Search/ProcessSearchBar.swift`) stays a platform `TextField`, so its text selection follows the *system* accent. Every other text field in the app is one of the hand-built ones above.
  **The settings toolbar's tab chrome is deliberately left alone.** Tinting the selected tab's icon was tried and reverted: supplying a non-template symbol to `NSToolbarItem.image` changes how AppKit draws the whole item (icon *and* label), and re-assigning the image makes AppKit rebuild the item and drop the toolbar's selected item — which visibly flipped the pane back to the first tab. The tab bar therefore keeps AppKit's native rendering, whose selection highlight follows the system accent. Touches `AppDelegate.swift`, `SettingsView.swift`, `AccentColor.swift`, `HistoryWindowView.swift`, `AlertLogView.swift`, `AppUsageView.swift`, and the new `AccentControls.swift`.

- **Settings window (0.3.0 milestones 18, 22).** A plain `NSWindow` hosting `SettingsRootView` — a **drawn tab bar** above the selected pane — created lazily by `AppDelegate.showSettingsWindow()` and resized per pane without animation. `SettingsView.swift` is now the window shell only (`SettingsTab` / `SettingsMetrics` / `SettingsRootView` / `SettingsTabBar` / `SettingsPanes`); since the 2026-09 file split, one pane per `SettingsTab` lives in its own `Settings*Pane.swift`, sharing the `SettingsRow` / `SettingsNote` / `SettingsPane` / `SettingsSwitch` / `EditableNumberField` / `AccentTimeField` components from `SettingsComponents.swift` — system fonts and semantic text styles, no hard-coded point sizes. Controls are platform controls except where a custom accent has to show (see milestone 19): `Toggle(.switch)`, `Picker`, `ColorPicker`, `Stepper`, `NSAlert`.
  **The tab bar is hand-drawn (milestone 22), not `NSTabViewController`'s toolbar tabs.** AppKit's preference-toolbar selection tints the selected item's *icon and label* with the system accent and has no override, but the requirement is a neutral highlight with no colour change — so the tab bar is five SwiftUI buttons showing `Color.primary` in every state, with selection expressed only by the background. Dropping the tab controller also removed three AppKit traps this window kept hitting: the child view-controller title rewriting the window title, item images having to be re-assigned (which dropped the toolbar's selection), and toolbar labels needing a manual locale refresh. Cost accepted: the window has no native toolbar chrome, and a pane is rebuilt on each switch, so its local `@State` resets.
  **Resize the window *outside* the `@Published` notification.** The pane-completion resize is deferred one runloop turn (`selection.$tab.sink { DispatchQueue.main.async { applyPaneSize(for: $0) } }`). Doing it synchronously inside the sink resizes the window but leaves the pane unchanged — the sink runs before the property is written, so the synchronous `setFrame` re-enters AppKit while SwiftUI is mid-update. Same family as the willSet pitfall in `.trellis/spec/guides/swift-combine-swiftui-pitfalls.md`. Touches `AppDelegate.swift`, `SettingsView.swift`, `HistoryWindowView.swift`, `AccentColor.swift`.
