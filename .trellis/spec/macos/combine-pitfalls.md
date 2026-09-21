//
//  macOS / combine-pitfalls.md
//  FlowTrace — Trellis spec
//
//  The bugs that have actually bitten this codebase, all rooted
//  in "SwiftUI / Combine update timing is not intuitive". For the
//  runtime traps we hit in localization / accent work, also see
//  the in-tree guide `.trellis/spec/guides/swift-combine-swiftui-pitfalls.md`.
//

# Combine & Reactive Pitfalls (macOS / SwiftUI)

## 1. `@Published` fires BEFORE the property is written (willSet)

`sink` on `$prop` re-reads `prop` against the **previous** value.
User-visible as "the setting takes effect one click late".

```swift
// WRONG — reads the old value
SettingsStore.shared.$refreshInterval
    .dropFirst()
    .sink { [weak self] _ in
        self?.apply(SettingsStore.shared.refreshInterval)
    }

// RIGHT — use the value the event carries
.sink { [weak self] newInterval in
    self?.apply(newInterval)
}
```

Hit in milestone 2 (sample interval) and milestone 12 (sort mode).
Both manifested as "first click does nothing, second click applies
the *previous* choice".

## 2. Do not put synchronous AppKit / AppStoreKit work inside a `@Published` sink

The sink runs before the property is written — same family as #1,
but the symptom is broader:

```swift
// WRONG — synchronously resizes the window; re-enters AppKit while SwiftUI
// is mid-update. Observed as the window resizes but the pane never
// changes (settings window, milestone 22).
selection.$tab.sink { tab in
    self.applyPaneSize(for: tab)   // ← no good
}

// RIGHT — defer one runloop turn. The property has been written by then.
selection.$tab.sink { tab in
    DispatchQueue.main.async { self.applyPaneSize(for: tab) }
}
```

Same fix applies to anything that needs to look at *the property
itself* (not just the event value): defer the call.

## 3. AppKit bridges keep stale titles across locale changes

`Picker(.segmented)` caches its segment titles. Switching the
language at runtime does **not** repaint the segment labels. The
fix is to rebuild the control:

```swift
Picker("", selection: $model.range) {
    ForEach(HeatmapRange.allCases) { Text(Loc.l($0.labelKey)).tag($0) }
}
.pickerStyle(.segmented)
.id(l10n.locale)             // ← rebuild on locale change
```

But: putting `.id(l10n.locale)` on the view **root** discards any
`@StateObject` inside it. Stamp the `.id` on the bridged control
individually, not on the root. The alert log's range picker follows
this pattern.

## 4. `removeDuplicates()` on a manager sink can swallow a real change

`LocalizationManager` deliberately omits `.removeDuplicates()`:

```swift
SettingsStore.shared.$languageOverride
    .sink { [weak self] new in
        guard let self else { return }
        self.locale = Self.resolveLocale(override: new)
        self.reloadBundle()
    }
```

If you wrap that with `.removeDuplicates()`, the "follow-system
→ zh-Hans → follow-system" toggle — which both resolve to
`zh-Hans` on a Chinese system — emits one event and the
subsequent revert is swallowed. The panes therefore only
re-render when the resolved locale string *differs*, which is
exactly the "second change is stuck" report.

If you are tempted to dedup elsewhere, ask: does the resolved
value depend on something outside the publisher's type? If yes,
drop the dedup.

## 5. Reading from a singleton inside an `.init` requires the singleton to exist

`SettingsStore.shared.$prop.sink { … }` subscribes the moment
`SettingsStore.shared` is first touched. If you write this at the
top of another singleton's `init`, and that singleton is *itself*
constructed before `SettingsStore.shared`, the subscription lands on
a half-initialised publisher.

In this repo, `LocalizationManager.shared` and `SettingsStore.shared`
are both constructed lazily; the order of first touch determines the
order. Tests of `SettingsStore` and `QuotaMonitor` use
`SettingsStore(defaults: aFreshSuiteDefaults)` to sidestep this.

## 6. NSHostingController dismissal is not a guarantee

The settings window rebuilds pane views on every tab switch.
A field torn down mid-edit never reports `controlTextDidEndEditing`,
so the typed value is dropped unless you commit it from
`controlTextDidEndEditing` / `NSControl.textDidEndEditingNotification` /
`NSWindow.willCloseNotification`. **Never commit from
`dismantleNSView`** — that path runs inside `NSHostingView.deinit`
→ `PlatformViewChild.destroy()`, and a `@Binding` write there trips
SwiftUI's exclusivity check and aborts the process with `EXC_CRASH`.
This is documented in detail in AGENTS.md milestone 19.