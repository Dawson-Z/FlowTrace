# Process knowledge base — PRD (retrospective, 2026-09)

> **This task was descoped.** The original PRD aimed to ship a
> bundled-JSON knowledge base for common macOS processes
> (`nsurlsessiond`, `cloudd`, …) so the user could hover a process
> row and see what it does. As of 0.3.0 (release notes
> 2026-09-21), this task has **no shipped code**.
>
> This PRD is preserved here as a record of intent and to make the
> descoping decision explicit.

## Goal (verbatim from the original task)

> 内置常见系统进程的知识库：解释进程作用、标注"限制/断网是否安全"
> 让用户看懂 `nsurlsessiond`、`cloudd`、
> `mds_stores` 这类名字。

## What was actually built

**Nothing.** The application ships no bundled JSON, no process-name
knowledge base, no hover-tooltip for system processes.

## Why it was descoped

Three reasons, ordered by weight:

1. **`AGENTS.md` forbids network requests.** A knowledge base that
   cannot fetch updates from the network stays frozen at the version
   that ships with the binary, which is the version that gets *most
   out of date fastest* for a moving target like macOS processes.
2. **The repository carries no third-party packages.** A locally
   curated, hand-maintained JSON of 30–50 process entries would be a
   permanent maintenance burden — every macOS minor release adds and
   retires processes, and the JSON would drift from reality unless
   kept current.
3. **The existing localization string tables already cover every
   label the app shows.** Process name *display* is handled by
   `getAggregatedAppInfo(name:)` and the system `NSRunningApplication`
   lookup. Adding a separate knowledge-base dictionary duplicates the
   role of system documentation (every entry is a paragraph that
   already lives in `man`, Apple developer docs, or a single Google
   search away).

## Acceptance criteria (status)

- [ ] 已收录进程在 popover 悬停可见一句话说明 — **Not built.**
- [ ] 匹配规则 standalone 全通过 — **N/A; no matcher exists.**
- [ ] 未收录进程无错误 UI — **Already holds**: unknown processes
  render as a `Text(processEntity.name)` with no decoration, which is
  the correct "no decoration" behaviour.
- [ ] 三语完整；零网络请求 — **Three-language already holds** via
  `Loc.l`; zero network calls already holds via `AGENTS.md`.

## Out of scope (unchanged)

- 在线知识库更新 (online knowledge base updates) — explicitly
  forbidden by `AGENTS.md`.
- 限速建议执行 (throttling-suggestion execution, "B 类") — never
  in this fork's scope.

## Constraints

- The PRD imagined a JSON file shipped in the bundle. The repo has
  no precedent for shipping a bundled JSON data file; all data
  lives either in code (string tables) or in the user's
  `~/Library/Application Support/FlowTrace/history.sqlite3`. A future
  contributor who wanted to revive this task would add
  `FlowTrace/Feature/Knowledge/processes.json` and a `ProcessKB`
  loader — but should weigh reasons #1–#3 above first.

## What a future contributor would do

If the constraint landscape changes (e.g. `AGENTS.md` is amended
to allow an opt-in network call for knowledge updates, or a
curated-by-the-user knowledge base becomes a real feature):

1. Create `FlowTrace/Feature/Knowledge/processes.json` with the schema
   in the original PRD (`name, displayName, description (zh-Hans /
   en / zh-Hant), risk: safe|caution|risk, category: system|app|daemon`).
2. Ship a `ProcessKB` loader at `FlowTrace/Feature/Knowledge/ProcessKB.swift`
   with one `static func match(name:) -> Entry?` (longest-prefix,
   case-insensitive, pure function — unit-testable).
3. Surface as a `.help(_:)` tooltip on `ProcessRow` in `ContentView.swift`,
   keyed off `l10n.locale`.

The schema and the matching logic are the only reusable bits from
the original PRD; everything else was UI scaffolding that has since
been superseded by the existing app's structure.

## References

- Original PRD (preserved): `prd.md` (the body above this note)
- Related: `AGENTS.md` (the "no network requests" rule that drove
  the descoping decision)
- Related: `docs/ARCHITECTURE.md` § 4.3 (`Feature/` module
  conventions a future `Knowledge/` module would follow)
