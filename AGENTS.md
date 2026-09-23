# AGENTS.md

Guidance for AI agents — and humans — working in this repository.

## This repository is a fork

FlowTrace is a fork of [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac) (*iTraffic*) and is MIT-licensed. It ships two ways: as source in this repository, and as a `.dmg` / `.zip` attached to each GitHub Release. There is no Mac App Store listing. The released binaries are signed with a self-signed certificate and are **not** notarised, so macOS blocks the first launch until the user allows it — § Releases covers how they are built and what changes when notarisation arrives.

Ideas flow one way only: **out of the upstream, into this fork** — never the reverse. The upstream is a separate, actively maintained project with its own goals, and this fork is allowed to diverge from it.

- **Never commit credentials, secrets, absolute home paths, or session logs.** The upstream's rule still applies here, and it is load-bearing rather than mere hygiene, because a commit is permanent: publishing is a one-way door, and rewriting history afterwards is expensive, does not reach anyone who already cloned, and does not undo a credential that has already been scraped. `.gitignore` covers the obvious cases (`.trellis/.developer`, `.claude/projects/`, `.codex/`); it is not a substitute for reading your own diff before you commit.
- **Do not** open a PR against the upstream, and do not push this fork's commits there.
- **Do not** copy private source, internal design documents, or commercial-only logic from any other product into this tree.
- **Keep `CODE_SIGN_IDENTITY: "-"` in `project.yml`.** A fresh clone has to build with no certificate installed. The release build overrides the identity on its own command line instead (§ Releases). Hard-coding an identity into the YAML would break the build for everyone who does not have that certificate, which defeats the point of shipping source.

## What this project is

FlowTrace is a fork of iTraffic. It inherits the upstream's core idea — a small, per-process macOS menu-bar network monitor driving `/usr/bin/nettop` — and adds features on top: process search, SQLite-backed traffic history, interface-aware sampling, and similar work that stays in user space without NetworkExtension or system entitlements.

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
  Feature/Usage/                     period totals, quota alerts, process alerts,
                                     local-notification delivery
FlowTraceForMac/                   upstream-derived app sources (several touched
                                   by this fork — see "Active experiments")
  Service/NettopRunner.swift       drives /usr/bin/nettop
  Network.swift                    parses frames, feeds the models
  Model/                           ObservableObjects backing the two surfaces
  ContentView.swift                popover: header + process list
  StatusBarView.swift              menu-bar rates
docs/ARCHITECTURE.md               architecture + per-file reference
project.yml                        XcodeGen source of truth
changelog/<version>.md             release notes (English)
changelog/<version>.zh-CN.md       release notes (Simplified Chinese)
```

`FlowTrace.xcodeproj` is generated from `project.yml` and is deliberately **not** committed — `.gitignore` says "never commit the rendered Xcode project". Edit the YAML, run `xcodegen generate`, and commit the YAML only (the project is rebuilt on demand; a fresh clone needs the `xcodegen generate` step above).

Two directories in this tree are tooling rather than app source. They are worth explaining, because they account for more than half the tracked files and not one of them is Swift:

- **`.trellis/`** — the project's working record, kept by the Trellis workflow system. `spec/` holds the conventions that constrain a change, `tasks/` holds one directory per feature with its PRD, design notes and implementation plan (including the ones deliberately deferred or descoped), and `workspace/` holds the session journal. It is committed on purpose: the reasoning behind a change is part of the project rather than a private note, and the deferred tasks are there so the next person does not re-derive them.
- **`.trae/`** — the platform adapter the same system generates for the IDE this project is developed in: agent definitions, hooks, skills, slash commands, and the commit-message rule. None of it is needed to build or run FlowTrace.

Neither directory affects the app. If you are here to understand the code, start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Debug
```

Unit tests live in `FlowTraceTests/` and run with `xcodebuild test -project FlowTrace.xcodeproj -scheme FlowTrace -configuration Debug` (205 cases as of 1.0.0). They cover the process-list comparator and merge, the network frame parser, the quota crossing rule, the per-process alert rule, the interface classifier, both SQLite pipelines (per-app usage, interface heatmap), the read-only query surface, the settings store, the accent-colour parsing, the 21 localization tables, and the local-notification delivery contract.

Real dependencies are injected rather than mocked: `SettingsStore(defaults:)`, `QuotaMonitor(settings:aggregator:defaults:)`, `ProcessAlertMonitor(settings:deliver:)` and `HistoryPersistence(dbURL:retentionSeconds:)` all take their collaborators as parameters, so a test can hand over a throwaway `UserDefaults` suite, a temporary database, and a stub `NotificationDelivery`.

**A test run is neither isolated nor read-only — treat that as a known property, not a bug.** The `FlowTraceTests` bundle runs *inside* the app (`TEST_HOST`), so `applicationDidFinishLaunching` executes for real: a run spawns the two `nettop` subprocesses and reads and writes the user's actual `~/Library/Application Support/FlowTrace/history.sqlite3` and `~/Library/Logs/FlowTrace.log`. Any test that goes through `Loc` / `LocalizationManager.shared` also instantiates `SettingsStore.shared`, which reads the real `UserDefaults` domain and can perform the one-time key migration there. Injecting isolated dependencies keeps each test's *assertions* honest; it does not sandbox the host app.
  The same fact cuts the other way: **anything modal presented at launch hangs the whole suite** — the launch notification reminder is `runModal()`, and while the permission was denied it held the main thread until two main-queue-awaiting tests timed out (measured 2026-09-23). `presentLaunchReminderIfNotSuppressed` therefore bails early under XCTest (`XCTestConfigurationFilePath`); any future launch-time UI needs the same guard.

When you need a genuinely clean room for a manual run, launch the built binary with `CFFIXED_USER_HOME=<dir>` — macOS resolves `NSHomeDirectory()` through `getpwuid()`, so the `HOME` variable alone does **not** redirect Application Support or Logs, while `CFFIXED_USER_HOME` does. It redirects file paths only; `UserDefaults` still resolves to the real domain.

Note when building locally: Xcode's index store under `~/Library/Developer/Xcode/DerivedData` can be blocked in a sandboxed shell. `-derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO` works around it.

`CODE_SIGN_IDENTITY` is ad-hoc (`-`) in `project.yml` so the project builds with no certificate at all. Releases are cut by hand — see below.

## Releases

No CI and no release script: a release is a handful of commands run by hand. This section exists so the next person can cut one without rediscovering the signing arrangement, because every step below is load-bearing in a way that is not obvious from the command itself.

### Version

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` both live in `project.yml`. Bump them, add `changelog/<version>.md` plus its `changelog/<version>.zh-CN.md` counterpart (the two are kept in step — same structure, same facts), then regenerate:

```bash
xcodegen generate
```

The version is read out of `project.yml` — `project.yml` is YAML, not a plist, so **don't use `plutil`** to extract it (on failure `plutil` passes the whole file through as one line, which silently breaks every downstream reference). `awk` is the right tool:

```bash
VERSION=$(awk '/^[[:space:]]*MARKETING_VERSION:/{sub(/^[^:]+:/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' project.yml)
```

### Build and sign

```bash
xcodebuild build -project FlowTrace.xcodeproj -scheme FlowTrace \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="<maintainer's signing identity>" CODE_SIGN_STYLE=Manual
```

Three non-obvious things about that command:

- **`-configuration Release` is what makes the binary universal.** Release uses `ARCHS_STANDARD`, so the product is `x86_64 arm64`; Debug builds only the host architecture. Never ship a Debug build.
- **The identity is passed here, not read from `project.yml`.** `project.yml` keeps `CODE_SIGN_IDENTITY: "-"` so anybody can build; the release overrides it. The identity has to be a *stable* one — ad-hoc signing produces a different identity on every rebuild, which breaks anything keyed to the bundle's identity across versions.
- **A self-signed identity is not a substitute for notarisation.** It buys a stable signature, nothing more. Gatekeeper still refuses the first launch, which is why the README has a "First launch" section.

The command above is confirmed working (Xcode 16.4, self-signed identity in the login keychain, `CODE_SIGN_STYLE=Manual` accepted with no team configured). Build it from `Terminal.app` — a sandboxed shell can be denied keychain access and fail in a way that looks like a project problem; see § `errSecInternalComponent` below.

### Verify before uploading

Several of the ways this goes wrong produce an app that runs perfectly on the machine that built it and fails for everyone else, so check the artefact instead of trusting the build log:

```bash
APP=build/Build/Products/Release/FlowTrace.app

lipo -info "$APP/Contents/MacOS/FlowTrace"    # architecture
codesign -dv --verbose=4 "$APP"               # identity, flags, team
spctl -a -vvv -t exec "$APP"                  # Gatekeeper's verdict
```

| Check | Expected | If it is wrong |
| --- | --- | --- |
| `lipo -info` | `x86_64 arm64`. The `Format=` line of the `codesign` output says the same thing: `Mach-O universal (x86_64 arm64)` | `Mach-O thin (arm64)` means host-architecture only, i.e. a Debug build. Never ship it — Intel Macs cannot run it at all. |
| `codesign -dv` → `Authority` | the identity's name | **The line missing entirely**, with `Signature=adhoc` instead, means signing did not happen and the build fell back to ad-hoc. `codesign` never prints `Authority=-`; the absence is the signal. |
| `codesign -dv` → `flags` | `0x10000(runtime)` with a real identity; `0x10002(adhoc,runtime)` when ad-hoc | `0x0(none)` means the hardened runtime is off, which blocks notarisation later — Debug, or a hand-rolled `codesign` without `--options runtime`. |
| `codesign -dv` → `TeamIdentifier` | `not set` | Expected for a self-signed identity — and precisely why Gatekeeper cannot verify the build. |
| `spctl -a` | **rejected** | Not a failure. An unnotarised app is supposed to be rejected, which is what the README's "First launch" section is for. |

The expected values above come from running these checks against a real `-configuration Release` build of this project, so the ad-hoc variants are the reference for "what a correct-but-unnotarised artefact looks like".

The combination to watch for is `Mach-O thin (arm64)` plus `flags=0x0(none)`: that is a Debug build wearing a Release path. Both halves are invisible at launch, which is why this check is not optional.

### Package

```bash
rm -rf dist && mkdir -p dist/dmg
cp -R build/Build/Products/Release/FlowTrace.app dist/dmg/
ln -s /Applications dist/dmg/Applications

# .dmg — app plus an /Applications alias, so installing is drag-and-drop
hdiutil create -volname FlowTrace -srcfolder dist/dmg \
  -ov -format UDZO dist/FlowTrace-<version>.dmg

# .zip — the same bundle without the disk image
ditto -c -k --sequesterRsrc --keepParent \
  build/Build/Products/Release/FlowTrace.app dist/FlowTrace-<version>.zip

shasum -a 256 dist/FlowTrace-<version>.dmg
```

`dist/` is gitignored. Tag the commit `v<version>` and attach both files to the GitHub Release, and paste the README's first-launch step into the release notes as well: the "damaged and can't be opened" wording reads as a corrupt download, and a user who never finds the workaround will report it as one.

### When notarisation arrives

Nothing above is thrown away, but three things change. The reason to care is not the first install: the Gatekeeper approval a user grants is attached to the copy they allowed, so **every release arrives with a fresh quarantine flag and re-blocks everyone**, including people already running an older version. Without notarisation that friction compounds with each release rather than amortising — which is what makes the annual fee worth arguing about instead of a nicety.

1. The identity becomes a Developer ID certificate rather than the self-signed one. That is the entire difference between "Gatekeeper blocks it" and "Gatekeeper accepts it", and it is the only part of this process that costs money (a paid Apple Developer Program membership). A self-signed certificate cannot be notarised.
2. A notarisation step slots in between signing and packaging: `xcrun notarytool submit` on the `.dmg`, then `xcrun stapler staple` the ticket onto it. Staple the disk image rather than the bare bundle — the ticket then travels with the file users actually download, so it works offline on first launch.
3. The README's "First launch" section gets deleted.

One thing is already in place: `ENABLE_HARDENED_RUNTIME` is on for Release, which is one of Apple's notarisation requirements. Without it the submission is rejected for a reason that reads as unrelated to signing.

### When signing fails with `errSecInternalComponent`

This is the one error in this process that reads as unrelated to its cause, so it is worth recognising. `codesign` reports it when it cannot reach the **private key**, even though the certificate is perfectly fine — so `security find-identity -v -p codesigning` cheerfully lists the identity while *every* signature fails. Diagnose it by signing a file that has nothing to do with this project:

```bash
cp /usr/bin/true /tmp/probe
codesign --force --sign <identity-hash> /tmp/probe
```

If that fails the same way, the build is not the problem and there is nothing to fix in this repository. Two causes, in order of likelihood:

1. **The key's partition list omits `codesign:`.** This is the usual outcome of a bare `security import` of a `.p12`. The narrow fix is to re-import that one identity with the ACL set:
   ```bash
   security import <cert>.p12 -k ~/Library/Keychains/login.keychain-db \
     -P <p12 password> -T /usr/bin/codesign -A
   ```
   The broad fix, which rewrites the partition list for the whole keychain and asks for the login password, is `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> ~/Library/Keychains/login.keychain-db`.
2. **An interactive keychain prompt is waiting where you cannot see it.** A key imported without `-A` asks permission the first time something uses it. Allowed once from a GUI session it is remembered from then on; missed or denied, every later non-interactive build fails exactly like this.

Run the release build from `Terminal.app`. A sandboxed shell — an IDE agent, a container — can be denied keychain access outright, which produces the identical error and hides the fact that the setup is fine.

#### Worked example on this machine (2026-09-23)

The `Dawson` identity (SHA-1 `BB1394A66CB92A22F19FCE4BA28735122D9807BD`) is the login keychain's only codesigning identity. The first real release build failed with `errSecInternalComponent` on `libswift_Concurrency.dylib`; the probe failed identically.

- **What didn't help**: running `set-key-partition-list -S apple-tool:,apple:,codesign: -s -k '<literal password>'` from an IDE shell. The literal `<...>` was taken as the password, the keychain rejected it as wrong, the command produced no ACL change, and the next signature failed the same way.
- **What did help**: the same `set-key-partition-list` invocation **without** `-k`, so the keychain pops its own password dialog. After that, the probe in the same `Terminal.app` returned `/tmp/probe: replacing existing signature` (no `errSecInternalComponent`), and the real `xcodebuild` succeeded.
- **The IDE shell was the wrong shell throughout**: the IDE-sandboxed shell saw `errSecInternalComponent` even *after* the ACL was fixed — because macOS's per-process keychain access is denied to sandboxed processes, and that denial produces the identical error message. The signal that you have the IDE-shell problem, not the ACL problem, is that the **probe fails even though the certificate looks fine to `find-identity`** and a sandboxed-process environment leaks (Trae IDE injects a long `env` block with `TRAE_SANDBOX_*` into every shell it spawns — visible by running `env | grep TRAE` in the failing shell).

Bottom line: if the probe fails in an IDE-spawned shell, **fix nothing in the keychain until you have reproduced the probe failure in `Terminal.app`**. Reproducing there is the only way to know whether the ACL is wrong.

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

- **The one file the fork writes into a directory it does not own is the launch agent, and only when asked.** On macOS 11–12, turning on "Launch at login" has `LaunchAtLoginManager` write `~/Library/LaunchAgents/local.FlowTrace.login.plist` — a launchd user agent whose single job is `/usr/bin/open -g` on this bundle. launchd scans that directory at every login, so the file's presence *is* the registration and deleting it is the unregistration; there is no `launchctl` call and no UserDefaults flag. macOS 13+ uses `SMAppService.mainApp` instead and writes nothing. This is a local preference rather than telemetry, so it sits outside the rule above — but it is the one place a reader auditing that rule needs to look.
  The app's *own* files are a separate matter and are not covered by that sentence: it always owns `~/Library/Application Support/FlowTrace/history.sqlite3` (plus its `-wal` and `-shm` sidecars — see `docs/ARCHITECTURE.md` §5.1 for the backup consequence) and, in Debug or with `ITRAFFICPLUS_FILE_LOG=1`, `~/Library/Logs/FlowTrace.log`.

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

- **Notification delivery (0.3.0 milestones 15, 16; reworked 2026-09).** Quota alerts and per-process alerts deliver through one injectable seam, `FlowTrace/Feature/Usage/LocalNotification.swift` (`typealias NotificationDelivery` plus `LocalNotification.deliver`). It reads `getNotificationSettings().authorizationStatus` **before** calling `add`, because `add` returns `error == nil` even when the app is not authorized — measured on this machine with the permission denied — so a caller that trusted the error would record the alert as sent and never retry. Quota writes a fired key only after a successful delivery; the alert monitor delivers *before* writing its `process_alert` dedup row; both back off for 15 minutes after a refusal, so a denied install cannot attempt (and log) on every check. `AppDelegate` startup also touches upstream code here: it calls `SharedStore.quotaMonitor.bootstrap()` — the monitor is a lazily-initialised `static let`, so without a touch its `init`, and therefore its subscriptions, never runs, which had left the quota feature completely dead — and `requestNotificationAuthorizationIfNeeded()`, which asks only while the status is `notDetermined`, and when it is `denied` both logs an error **and** presents the launch reminder alert (what breaks, a button to System Settings → Notifications, and a "Don't remind me again" opt-out persisted under `notificationLaunchReminderSuppressed`; suppressed under XCTest because a launch-time `runModal()` hangs the suite — see Build). The Settings Quota, Alerts and Storage panes surface the same state visually: each owns a `NotificationPermissionModel` (`@StateObject`, refreshed on pane appear — panes rebuild on every tab switch — and after its toggle/picker requests permission), and `NotificationPermissionWarning` (`SettingsComponents.swift`) shows an inline orange row while the notification deliverable is enabled but the status is `denied` (button opens System Settings → Notifications) or `notDetermined` (button asks directly); for the Storage pane that means cleanup mode = the reminder mode. Touches `AppDelegate.swift`, `QuotaMonitor.swift`, `ProcessAlertMonitor.swift`, `DataRetentionController.swift`, `SettingsQuotaPane.swift`, `SettingsAlertsPane.swift`, `SettingsStoragePane.swift`, `SettingsComponents.swift`, and the new `LocalNotification.swift`.

- **Interface classification precedence (0.3.0 milestone 9; corrected 2026-09).** `InterfaceClassifier.classify` now runs two name heuristics *before* the hardware-port table (`awdl0`/`llw0` → Local Direct, `bridge*` → Other), then the table (a port containing `wifi`/`wi-fi` → Wi-Fi, `usb`/`ethernet`/`thunderbolt` → Wired), then numeric `en*` → Wired. Three things in the original order were wrong or unreachable: `== "wifi"` never matched because `networksetup` reports the port as `Wi-Fi`, which lowercases to `wi-fi`, so this machine's Wi-Fi NIC (`en1`) was bucketed as Other; `dropFirst()` had to be `dropFirst(2)`, so dynamic interfaces such as `en13` fell to Other as well; and `bridge0` never reached the bridge branch because its port name `Thunderbolt Bridge` matched `thunderbolt` first. Fork code, not upstream, but the behaviour is documented in `docs/ARCHITECTURE.md` §4.3. `InterfaceClassifierTests` keeps a regression case built from this machine's real `networksetup -listallhardwareports` output.
