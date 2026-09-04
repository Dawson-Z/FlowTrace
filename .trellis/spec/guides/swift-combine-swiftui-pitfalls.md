# Swift / Combine / SwiftUI Pitfalls (macOS)

> Earned from iTrafficPlus 0.3.0 localization work (2026-09-04). Three bugs,
> one root theme: **SwiftUI/Combine update timing is not intuitive — never
> assume a value is "already there" when an event fires.**

---

## 1. `@Published` fires BEFORE the property is written (willSet semantics)

**Symptom**: A `sink` on `$prop` that re-reads `prop` acts on the *previous*
value. User-visible as "the setting takes effect one click late" or "I must
tap twice".

```swift
// WRONG — reads the old value (willSet hasn't completed the write yet)
SettingsStore.shared.$refreshInterval
    .dropFirst()
    .removeDuplicates()
    .sink { [weak self] _ in
        self?.apply(newInterval: SettingsStore.shared.refreshInterval) // ← OLD value
    }

// RIGHT — use the value carried by the event
.sink { [weak self] newInterval in
    self?.apply(newInterval: newInterval)
}
```

**Cases hit in one session**: `refreshInterval` (Network collector restart),
`sortMode` (re-sort on switch — sorted with the *previous* mode). The
`languageOverride` path worked *only because* it happened to use the event
parameter.

**Rule**: In any `$prop` sink, the event parameter IS the new value. Never
re-read the property inside the sink.

---

## 2. macOS segmented Picker (`NSSegmentedControl` bridge) quirks

### 2a. Segment labels do not refresh when only their text changes

Changing a segment's `Text` (e.g. after a language switch) does not repaint
the bridged control. Fix: force a rebuild by keying the view on the changing
value:

```swift
Picker(..., selection: $mode) { ... }
    .pickerStyle(.segmented)
    .id(l10n.locale)   // rebuild → fresh labels
```

### 2b. Static windows: selection highlight lags one event

On a window with no periodic re-render source, a segmented Picker bound
**directly** to `@Published` highlights one event late (the 2a-style willSet
race, visible because nothing else repaints). Popovers hide this bug when a
nettop frame repaints every ~2 s.

Fix: bind to a `@State` mirror; write both in the setter:

```swift
@State private var localInterval: Int = SettingsStore.shared.refreshInterval

Picker(..., selection: Binding(
    get: { localInterval },
    set: { localInterval = $0; store.refreshInterval = $0 }  // UI first, data second
))
.pickerStyle(.segmented)
.id(l10n.locale)
```

`@State` writes have an immediate, synchronous render contract — no willSet
race.

---

## 3. `Bundle.localizedString` — "found" detection when value == key

Checking `value != key` to decide whether a key was translated **breaks for
English**, where every value equals its key (`"Settings" = "Settings"`): the
check always reports "missing" and falls through to the main bundle (i.e.
the system language). Use a sentinel instead:

```swift
private static let missing = "__missing__"

let value = bundle.localizedString(forKey: key, value: Self.missing, table: table)
if value != Self.missing { return value }   // found
```

**Rule**: Any "did the API return what I asked for?" check must compare
against a sentinel that cannot collide with real data, never against the
input itself.

---

## 4. Checklist before shipping a Combine-driven setting

- [ ] Sink uses the event parameter, not a property re-read
- [ ] Segmented pickers: labels rebuild on locale change (`.id(locale)`)
- [ ] Segmented pickers on static windows: selection via `@State` mirror
- [ ] Localization "found" checks use a sentinel, not `value != key`
- [ ] Verified with a *single* click after a fresh app launch (not the
      second click — the first is the one that exposes the race)
