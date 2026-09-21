# Process knowledge base — Implementation plan (retrospective, 2026-09)

**No implementation was produced.** This file exists so the
task has a complete `prd.md` / `design.md` / `implement.md` /
two JSONL / `task.json` set, even though the implement log is
empty by intent.

## Why "implement.jsonl" is empty

The Trellis task system expects `implement.jsonl` to list the
spec files and code files an implement agent should load. For a
descoped task, that list is the **spec files that would constrain
any future implementation**:

- `.trellis/spec/macos/index.md` — top-level conventions
- `.trellis/spec/macos/swiftui-conventions.md` — view / tooltip
  patterns
- `.trellis/spec/macos/localization.md` — `Loc.l` for the
  three-language description fields

There are no code files to load, because no code was written.
That is what the implement log reflects.

## Implementation plan if this task is reopened

If the constraints change (network rule relaxed, or a curated
JSON becomes acceptable), the work breaks into:

1. **Schema + JSON.** Create `FlowTrace/Feature/Knowledge/processes.json`
   with the schema documented in `design.md`. Start with 10–15
   entries (the actual common macOS processes the user is likely
   to hover); grow from there. The JSON is the entire data layer.
2. **Pure matcher.** Create `FlowTrace/Feature/Knowledge/ProcessKB.swift`
   with the `match(name:)` function from `design.md`. Longest-prefix,
   case-insensitive, no fallback. Unit-test the matcher.
3. **Tooltip hook.** In `FlowTraceForMac/ContentView.swift`'s
   `ProcessRow`, attach `.help(kb?.description(locale: l10n.locale) ?? "")`
   to the row's `HStack`.
4. **Localization of description field.** Use `Loc.l(key, table:)`
   per PRD: pass the matched `Entry`'s description through
   `Loc.l(entry.descriptionKey)` so it follows the user's language.
   (Or hard-code three description fields keyed by `l10n.locale`,
   which is what the original schema imagined.)
5. **App-usage tab integration.** Mirror the tooltip in
   `AppUsageView.swift` so users get the same hint in both surfaces.

## What the milestone would look like in changelog/0.3.0.md

```markdown
### 0.3.0 (research milestone N — new) — Process knowledge base

### Added
- `FlowTrace/Feature/Knowledge/processes.json` — curated JSON of
  the most-common macOS processes with one-line descriptions in
  three languages.
- `FlowTrace/Feature/Knowledge/ProcessKB.swift` — pure longest-prefix
  matcher; unit-tested.
- Hover tooltip on `ProcessRow` showing the matched description
  in the user's current locale.
```

The above is a sketch, not a shipped entry. It exists to show the
shape of the change a future contributor would commit.

## Why this file is not titled "no implementation"

This task is in `planning` because no implementation was produced.
The `task.json` carries `status: planning`, `completedAt: null`,
and `meta.descriptor: "Descoped — see design.md"`. A future
contributor would move it to `in_progress` by calling
`task.py start …` and back to `completed` after shipping.
