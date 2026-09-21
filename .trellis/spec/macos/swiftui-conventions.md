//
//  macOS / swiftui-conventions.md
//  FlowTrace — Trellis spec
//
//  Patterns the codebase actually uses for SwiftUI views. Each
//  section is anchored on a real file path so the agent can read
//  the cited code while writing.
//

# SwiftUI Conventions

## `@StateObject` is for the lifetime of the *view*, `@ObservedObject` is for *what the view consumes*

```swift
// FlowTraceForMac/ContentView.swift
struct ContentView: View {
    @StateObject var viewModel = SharedStore.listViewModel        // singleton owned via @StateObject
    @StateObject var historyStore = SharedStore.historyStore
    @ObservedObject var settings = SettingsStore.shared           // consumed, not owned
    @ObservedObject private var l10n = LocalizationManager.shared
    @ObservedObject private var accent = AccentColorManager.shared
    ...
}
```

The distinction matters: `@StateObject` keeps the same instance across
re-renders. `@ObservedObject` re-subscribes each time the parent re-creates
the view. For singletons, `@StateObject(wrappedValue:)` is the correct
choice and is what every Feature module does.

`Network` and `AppDelegate` were *deliberately downgraded* from
`@ObservedObject` to plain references in milestone 2 — the wrapper
is a no-op on a type with no `body`, so the published subscription
is never consumed.

## One window root, one accent scope

`.tint` reaches SwiftUI-drawn controls. AppKit-drawn controls ignore it.
The accent subsystem lives in `FlowTrace/Feature/Appearance/`, and its
sole hand-build pattern is:

```swift
// FlowTrace/Feature/Appearance/AccentControls.swift
@Environment(\.appAccent) private var accent
// …
.environment(\.appAccent, accent)   // re-publish inside the popover
```

**Rule:** every SwiftUI root that hosts an `NSHostingController` on
its own (settings window hosts one *per pane*) must apply `.appAccentScope(_:)`
itself. See AGENTS.md milestone 19.

## Bridges to AppKit are not SwiftUI

`Picker(.segmented)`, `Toggle(.switch)`, `NSHostingController`,
and `AccentTextField` (the hand-built `NSTextField`) are bridged
views. They:

- Do not inherit `.tint` (see above).
- Do not wrap or truncate text the way a `Text` does — they
  **overdraw** their neighbours when the row is too narrow.
- Keep their `localizedString` tables stale across locale changes;
  rebuild them by `.id(l10n.locale)`.

Concrete consequences:

- **Never give a bridged control a fixed `width`** unless you have
  measured that all shipped locales fit. The history window's three
  range pickers used to be `width: 300`, which overdraws in any
  language where "Last 30 days" is longer than 6 characters.
- **Stamp `.id(l10n.locale)`** on every bridged control whose label
  comes from `Loc.l(_:)`. (Note: this rebuild discards the
  user's selection state — do **not** put it on a view root that
  owns a `@StateObject`; put it on the bridged control instead, as
  the alert log range picker does.)

## Single `NSHostingController` per window root, not per tab

The settings window hosts one `NSHostingController` **per
`SettingsTab`** (`SettingsPanes.view(for:)`), so there is no shared
parent for `.tint` to reach. Every pane therefore applies the accent
scope itself:

```swift
// FlowTrace/Feature/Settings/SettingsComponents.swift
struct SettingsPane<Content: View>: View {
    @ObservedObject private var accent = AccentColorManager.shared
    var body: some View {
        content
            .appAccentScope(accent.accent)
    }
}
```

If you add a new pane, it must go through `SettingsPane`, or apply
the scope itself.

## Hand-drawn controls replace AppKit where AppKit cannot follow the custom accent

When the chosen accent must show through (selection ring, hover
highlight, text-selection colour), the platform control reads its
colours from app-wide semantic colours that no public API can
override. So the codebase ships its own in `AccentControls.swift`:

- `AccentTextField` — borderless `NSTextField` with the focus ring
  suppressed, wrapped in `.accentFieldChrome(isFocused:)` to paint
  a ring in the chosen colour; selection colour rewritten via
  `selectedTextAttributes`.
- `AccentPicker` — popover list with `Color.primary`; reads
  `appAccent` and chooses foreground luminance against
  `AccentColorManager.readableForeground(on:)`.
- `AccentDateField` — month grid (see the localization guide for
  the locale-handling rules).

If you are adding a control where AppKit overrides would matter,
add the control there and document the trade-off in AGENTS.md.

## `LineLimit(1)` plus `MinimumScaleFactor` inside fixed columns

Inside the alert log's fixed-width column cells, Russian "Median (7d)"
measures 74 pt against a 76 pt column. Wrapping would grow the
header row and carry the sort underline with it. So:

```swift
.lineLimit(1)
.minimumScaleFactor(0.75)
```

is the standard recipe for a fixed-column header / cell that may
have one long translation. The history window uses this on every
sortable column header in `AlertLogView` and `AppUsageView`.

## Do not put `lineLimit(1)` on a control that should *always* fit

When the column width is already intrinsic (`Picker` / `Toggle` after
the 9.6 fix), `lineLimit(1)` is wrong: it would now truncate what
should be displayed. Restrict `lineLimit(1)` to fixed-width columns,
not intrinsic-width rows.

## `id(l10n.locale)` is a rebuild — be deliberate

Putting `.id(l10n.locale)` on a view that owns `@StateObject`
discards the model's state. The history window puts it on each
bridged control individually for that reason. See
`.trellis/spec/macos/combine-pitfalls.md` for the related
`@Published`-fires-before-write rule, which is the same family.