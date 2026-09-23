# Trellis Spec — Top-Level Index

> Entry point for every Trellis agent and every human maintainer
> in the FlowTrace repo. **Read this file first.** It tells you
> where to find the conventions that apply to your change.

## Project under spec

FlowTrace is a **macOS menu-bar app** in Swift + SwiftUI,
deployment target **11.0**. It is a fork of
[iTraffic](https://github.com/foamzou/ITraffic-monitor-for-mac) with
no third-party packages, no network requests, and an empty
entitlements file. Anything you read below must be consistent with
[`AGENTS.md`](../../../AGENTS.md) at the repo root — when this spec
and `AGENTS.md` disagree, **`AGENTS.md` wins**.

---

## Contents

| Path | What it is | Read when |
| --- | --- | --- |
| [**macos/index.md**](./macos/index.md) | **The project's real spec.** Index of five sub-guides covering project layout, SwiftUI, Combine, localization, persistence. | Almost always — start here. |
| [macos/project-layout.md](./macos/project-layout.md) | `FlowTraceForMac/` vs `FlowTrace/Feature/<Name>/`, target wiring, import rules, the AGENTS.md tie-breaker. | Touching any file under either tree. |
| [macos/swiftui-conventions.md](./macos/swiftui-conventions.md) | `@StateObject` vs `@ObservedObject`, accent scope, AppKit bridge rules, `lineLimit` + `minimumScaleFactor`. | Adding / modifying a view. |
| [macos/combine-pitfalls.md](./macos/combine-pitfalls.md) | `@Published` willSet race, deferred UI updates, AppKit staleness across locale changes. | Adding a sink, picker, hosting controller, or timer. |
| [macos/localization.md](./macos/localization.md) | `Loc.l`, `Loc.dateFormatter`, the **locale-before-template** order trap, supported locales, what's machine-facing. | Any user-visible string or date. |
| [macos/persistence.md](./macos/persistence.md) | SQLite schema, queue model, two time bases, three pruning paths. | Touching `HistoryPersistence` or any new persisted aggregate. |
| [guides/index.md](./guides/index.md) | Thinking guides — when to load what. | Read once; reread before starting a task. |
| [guides/code-reuse-thinking-guide.md](./guides/code-reuse-thinking-guide.md) | Identify repeated patterns before writing new code. | When adding a new utility / helper. |
| [guides/cross-layer-thinking-guide.md](./guides/cross-layer-thinking-guide.md) | Data-flow traps across layers. | Features that span three or more layers. |
| [guides/swift-combine-swiftui-pitfalls.md](./guides/swift-combine-swiftui-pitfalls.md) | Older long-form version of the same traps as `macos/combine-pitfalls.md`, with more code examples. | Use in tandem with `macos/combine-pitfalls.md` — read one, not both. |

---

## What this directory is **not**

There is no `frontend/` or `backend/` here. That layout was the
web-stack default, and it does not apply to a macOS menu-bar app.
There is also no `Components/` or `Hooks/` — those are React-isms
that would mislead an agent. This directory has been **trimmed**
to what is real for the project. If you are tempted to add a
generic "common" or "frontend" directory, stop: every place it
has been tried in this repo has ended up as a dumping ground.

---

## What lives outside `.trellis/spec/`

| Concern | Where it lives | Why |
| --- | --- | --- |
| Hard rules (deployment target, no network, no third-party deps, etc.) | `AGENTS.md` at repo root | They change rarely and the agents' preamble references them by name. |
| Per-milestone feature / convention decisions | `AGENTS.md` § Active experiments | The agents' preamble reads AGENTS.md anyway; keeping it there means one place to scan. |
| Per-file architecture + per-file reference | `docs/ARCHITECTURE.md` | Manually maintained prose; not loaded automatically by agents. |
| Per-release changelog | `changelog/0.3.0.md` | Historical record. |
| Trellis workflow scripts | `.trellis/scripts/*.py` | Operational, not normative. |

---

## How to keep this directory honest

The guides in `macos/` are anchored on real code paths — every
"do this" or "don't do that" cites a file:line. If you change a
file the guide cites, **update the guide in the same commit**.
Stale guides are worse than no guides: they mislead future agents
and waste review cycles.

If a new pattern emerges (a new bug class, a new XcodeGen
quirk, a new locale-related trap), add it to the relevant
`macos/` sub-guide and add a one-line entry to the "Common
false-positives" list in `agents/check.md`.