<div align="center">

# FlowTrace

A local-only research fork of [iTraffic](https://github.com/foamzou/ITraffic-monitor-for-mac), kept on a developer machine. Inherits the upstream idea — small, per-process macOS menu-bar network monitor driving `/usr/bin/nettop` — and adds in-memory experiments on top: process search, traffic history, and the like.

</div>

**This fork is not published. It does not ship, does not sign, does not notarise, and is not on any release channel.** All experiments are done in user space; no System Extension, no NetworkExtension, no extra entitlements.

## What it inherits

- `/usr/bin/nettop` driven directly from Swift, with the [upstream's two non-obvious nets](https://github.com/foamzou/ITraffic-monitor-for-mac/blob/main/ITrafficMonitorForMac/Service/NettopRunner.swift) still in place (TTY wrap + retained stdin pipe).
- Per-process upload/download in a popover, total rates in the menu bar.
- The 1-second sample / delta mode / first-frame-dropped rule.
- The "do exactly one network request, only when clicked" rule — except this fork has **no** network request, since there is no release channel to check.

## What is new in this fork

See [AGENTS.md](AGENTS.md) § Active experiments for the live list, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full per-file reference.
As of 0.3.0 the fork adds, on top of the upstream:

- **Process list** — search by name or PID, six sort modes, same-name process
  merge, and a live "today" column per row.
- **History** — SQLite-backed frame history (survives restarts) behind the
  popover sparkline, plus a standalone window with an app-usage table, an
  hour × day network heatmap and an abnormal-traffic alert log, each
  exportable to CSV.
- **Interface dimension** — a second, independent `nettop` in socket mode
  splits external traffic into Wi-Fi / Wired / Local Direct / Other.
- **Usage** — period totals in the menu bar, quota-threshold alerts and
  per-process abnormal-traffic alerts.
- **Settings window** — retention and cleanup, quota, alerts, appearance,
  accent colour and 21 languages, all applied at runtime.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project FlowTrace.xcodeproj -scheme FlowTrace -configuration Debug build
```

Or open `FlowTrace.xcodeproj` in Xcode and ⌘R. Output binary is `FlowTrace.app`.

There is no `scripts/release.sh`; this fork does not ship.

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
                                   by this fork — see AGENTS.md)
  Service/NettopRunner.swift       drives /usr/bin/nettop
  Network.swift                    parses frames, feeds the models
  Model/                           ObservableObjects backing the two surfaces
  ContentView.swift                popover: header + process list
  StatusBarView.swift              menu-bar rates
docs/ARCHITECTURE.md               architecture + per-file reference
project.yml                        XcodeGen source of truth
changelog/<version>.md             release notes for this fork
```
