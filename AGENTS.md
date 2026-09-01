# AGENTS.md

Guidance for AI agents — and humans — working in this repository.

## This repository is private, local-only

This is a research fork of [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac), kept on a developer machine for local experimentation. It is **not** published, not on Homebrew, not on GitHub Releases, and not on the Mac App Store.

Because the fork is private, the "never commit credentials / paths / session logs" rule of the upstream AGENTS.md is still good hygiene but is no longer load-bearing. The bigger concern here is keeping the fork cleanly separated from the upstream so that ideas flow one way only: **out of the upstream, into this fork** — never the reverse.

- **Do not** push this repository anywhere, **do not** open a PR against the upstream.
- **Do not** copy private source, internal design documents, or commercial-only logic from any other product into this tree.
- **Do not** re-enable the upstream's notarisation / Developer ID signing / Homebrew Cask pipeline. The Release scheme in `project.yml` keeps the hardened runtime but otherwise leaves signing ad-hoc.

## What this project is

iTrafficPlus is a local-only research build of iTraffic. It inherits the upstream's core idea — small, open-style, per-process macOS menu-bar network monitor driving `/usr/bin/nettop` — and adds local-only experiments on top: process search, in-memory traffic history, interface-aware sampling, and similar features that can be done in user space without NetworkExtension or system entitlements.

The experimental features are **not** the same as anything shipped by any other product from the same author. They are designed from Apple public documentation and the upstream's user-state code, full stop.

## Layout

```
iTrafficPlus/                      fork-specific experiments
  Feature/Search/                  process search (0.3.0 milestone 1)
  Feature/History/                 in-memory ring buffer + sparkline
ITrafficMonitorForMac/             upstream-style app sources (carried as-is)
  Service/NettopRunner.swift       drives /usr/bin/nettop
  Network.swift                    parses frames, feeds the models
  Model/                           ObservableObjects backing the two surfaces
  ContentView.swift                popover: header + process list
  StatusBarView.swift              menu-bar rates
project.yml                        XcodeGen source of truth
changelog/<version>.md             release notes for this fork
```

`iTrafficPlus.xcodeproj` is generated from `project.yml`. Edit the YAML, run `xcodegen generate`, and commit both.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild build -project iTrafficPlus.xcodeproj \
  -scheme iTrafficPlus -configuration Debug
```

`CODE_SIGN_IDENTITY` is ad-hoc (`-`) in `project.yml` so the project builds with no certificate at all. There is no `scripts/release.sh` analogue here; this fork does not ship.

## Conventions carried from upstream

- **Rates carry their unit in the field name** (`inBytesPerSec`, `totalInBytesPerSec`). `nettop` runs in delta mode over a 2-second sample, so a frame reports bytes moved across the whole window, not a rate. Normalise once in `Network.parser`, at the single point where nettop numbers enter the app, and never re-derive downstream. Issue #28 in the upstream was exactly this: the divide was moved up to the aggregation point, the status bar got it, the process list did not, and every row rendered double for three months.

- **The app makes exactly one network request, and only when clicked.** The upstream's update checker hits the GitHub releases API when the user clicks the version number. We have stripped the upstream's `UpdateChecker.swift` and any network call from this fork because (a) the upstream is a moving target, and (b) the rule — "iTraffic lists the network activity of every process including its own, so a background poll appears to users as unexplained traffic from the one tool whose job is to explain traffic" — applies here too. Any future network work in this fork stays on the same rule.

- **`.help(_:)` is macOS 11+** while the deployment target is 10.15. Guard new API with `#available` rather than raising the target.

- **Size SF Symbols with `.font`, never `.resizable()`** — resizing stretches them into thin sticks at menu-bar sizes. A Unicode glyph in a `Text` avoids the question entirely and works on 10.15.

## Fork-specific conventions

- **Feature modules live under `iTrafficPlus/Feature/<Name>/`** and are self-contained: each module owns its view(s), its model, and any pure-function helpers. `iTrafficPlus/Feature/...` files are added to the Xcode target the same way `ITrafficMonitorForMac/...` files are.

- **Experiments that touch the upstream code must document the touch point** in this AGENTS.md. If you change `ContentView.swift` to host a new search bar, say so here under "Active experiments". Without that note, the next person has to read the diff to know which upstream file is no longer vanilla.

- **No data leaves this machine.** No telemetry, no analytics, no remote update check, no remote catalog fetch. The fork may read `/Applications/...` to extract an icon, but it does not read, parse, or otherwise touch any other product's binaries or private data structures.

## Active experiments

- **Process search bar (0.3.0 milestone 1).** Adds a `SearchFilter` to `ListViewModel` and a `ProcessSearchBar` view at the top of the popover. Touches `ContentView.swift` and `ListViewModel.swift`.
- **In-memory history ring buffer (0.3.0 milestone 1).** Adds `RingBuffer`, `HistoryStore`, and `HistoryView` (a 60-sample sparkline) at the bottom of the popover. Touches `Network.swift` (to push frames into the store) and `ContentView.swift` (to host the view).
