<div align="center">

# iTrafficPlus

A local-only research fork of [iTraffic](https://github.com/foamzou/ITraffic-monitor-for-mac), kept on a developer machine. Inherits the upstream idea — small, per-process macOS menu-bar network monitor driving `/usr/bin/nettop` — and adds in-memory experiments on top: process search, traffic history, and the like.

</div>

**This fork is not published. It does not ship, does not sign, does not notarise, and is not on any release channel.** All experiments are done in user space; no System Extension, no NetworkExtension, no extra entitlements.

## What it inherits

- `/usr/bin/nettop` driven directly from Swift, with the [upstream's two non-obvious nets](https://github.com/foamzou/ITraffic-monitor-for-mac/blob/main/ITrafficMonitorForMac/Service/NettopRunner.swift) still in place (TTY wrap + retained stdin pipe).
- Per-process upload/download in a popover, total rates in the menu bar.
- The 2-second sample / delta mode / first-frame-dropped rule.
- The "do exactly one network request, only when clicked" rule — except this fork has **no** network request, since there is no release channel to check.

## What is new in this fork

See [AGENTS.md](AGENTS.md) § Active experiments for the live list. As of 0.3.0 (research milestone 1):

- **Process search bar.** Filter the process list by name or PID without leaving the popover.
- **In-memory history.** A 2-minute ring buffer of total in/out, drawn as a 60-sample sparkline at the bottom of the popover.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project iTrafficPlus.xcodeproj -scheme iTrafficPlus -configuration Debug build
```

Or open `iTrafficPlus.xcodeproj` in Xcode and ⌘R. Output binary is `iTrafficPlus.app`.

There is no `scripts/release.sh`; this fork does not ship.

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
