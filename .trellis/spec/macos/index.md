//
//  macOS (Swift) Development Guidelines
//  FlowTrace — Trellis spec root
//
//  Index for every project-level guideline an implement / check agent
//  should load when working on FlowTrace. The repo is a macOS menu-bar
//  app in Swift / SwiftUI; the topics below match what the codebase
//  actually does, and each file contains code examples drawn from it.
//
//  Agents load only what is relevant to the diff under review — not
//  every file, every time. The topical index below says which one.
//

# FlowTrace — macOS (Swift) Development Guidelines

> Best practices for the FlowTrace codebase. This directory exists
> because the project's actual surface area is SwiftUI + Combine +
> Foundation + SQLite (via `import SQLite3`), not a web stack. If a
> guideline here conflicts with a generic "frontend / backend"
> convention, this index wins.

---

## What this project is

- **Stack**: Swift 5, macOS deployment target **11.0**, XcodeGen
  (`project.yml`) → no third-party packages, only the system
  `SQLite3` library.
- **Two source trees**:
  - `FlowTraceForMac/` — app main (entry point, popover, menu bar,
    models, parser, nettop subprocess driver). Inherited from the
    upstream iTraffic fork.
  - `FlowTrace/Feature/<Name>/` — eight self-contained feature modules
    added by this fork: Appearance, History, Interface, Localization,
    Logging, Search, Settings, Usage.
- **Tests**: `FlowTraceTests/` is a `bundle.unit-test` target — pure
  Swift, real dependency injection (`SettingsStore(defaults:)`,
  `QuotaMonitor(settings:aggregator:defaults:)`), real temporary
  SQLite databases. No UI tests, no screenshots. Run with
  `xcodebuild test -project FlowTrace.xcodeproj -scheme FlowTrace
  -configuration Debug`. Under sandboxed shells add
  `-derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO`.

---

## Guidelines Index

| Guide | Description | Load when |
| --- | --- | --- |
| [Project Layout](./project-layout.md) | `FlowTraceForMac/` vs `FlowTrace/Feature/<Name>/` boundary, target wiring, what's allowed to import what. | Any file-touch. |
| [SwiftUI Conventions](./swiftui-conventions.md) | `@StateObject` vs `@ObservedObject`, environment injection, single `NSHostingController` per window root, hand-drawn controls that *replace* AppKit. | Adding / modifying any view. |
| [Combine & Reactive Pitfalls](./combine-pitfalls.md) | `@Published` willSet race, deferred UI updates from `@Published` sinks, AppKit bridge staleness across locale changes. | Touching `Combine` sinks, `Picker(.segmented)` / `Toggle(.switch)`, or `NSHostingController` lifecycles. |
| [Localization](./localization.md) | `Loc.l`, `LocalizationManager.shared`, `Loc.dateFormatter(template:locale:)`, the **locale-before-template** order trap, "what is and is not a machine-facing timestamp". | Any user-visible string or date; adding a new locale. |
| [Persistence (SQLite)](./persistence.md) | `HistoryPersistence` schema, queue model, two time bases (`ts` epoch-ms vs `minute_bucket` local-min ordinal), the three distinct prune paths. | Touching the SQLite layer or any new persisted aggregate. |

---

## Where to read first

1. **Project Layout** — if you do not understand why `FlowTrace/`
   and `FlowTraceForMac/` are separate, you will write into the
   wrong tree.
2. **SwiftUI Conventions** — the most common change type. Almost
   everything new lives in `FlowTrace/Feature/<Name>/`.
3. **Combine & Reactive Pitfalls** — read this **before** writing a
   sink / timer / `@Published` consumer. The bugs it documents are
   subtle and the same themes recur.
4. **Localization** — read whenever any text or date touches the
   UI. The `Loc` helpers and `setLocalizedDateFormatFromTemplate`
   ordering trap are the single most common silent-bug source in
   this codebase.

---

## Hard rules (do not violate)

These are non-negotiable; they were each earned from a real bug.

- **Never commit, push, or open a PR upstream.** (AGENTS.md.) This is
  a private research fork, kept separate from
  [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac).
- **No third-party dependencies.** `import SQLite3` is the only
  non-system dependency. If you need a JSON parser, use `Codable`.
- **No network requests of any kind.** Upstream's `UpdateChecker.swift`
  has been stripped on purpose. Adding a network call would violate
  the "this tool lists every process's traffic including its own" rule.
- **Normalise `nettop` bytes only once**, in `Network.parser`. The
  field name carries the unit (`inBytesPerSec`,
  `totalInBytesPerSec`); dividing again downstream was issue #28
  upstream — see the SwiftUI Conventions guide.
- **The first frame of every new pid is dropped** by
  `ProcessUsageAggregator` — nettop reports it as cumulative-since-launch,
  not as a delta. Reproduced as a regression test.

---

## How to fill these guidelines

Each guideline file in this directory documents **what the codebase
actually does**, with code citations. When the codebase changes
(an entry point gets renamed, a primitive gets retired), update the
relevant file in the same commit. Stale docs are worse than no docs.

---

**Language**: All documentation in this repo is English. App UI
strings are localized via `Loc.l(_:)`; this index is for agents and
maintainers only.