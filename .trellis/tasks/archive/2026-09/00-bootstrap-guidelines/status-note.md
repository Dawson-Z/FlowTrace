# 00-bootstrap-guidelines — Status Note (2026-09)

**Note for Trellis readers**: the spec/ subtree this task originally
enumerated (frontend/, backend/) has been removed. It was a web-stack
default; FlowTrace is a macOS Swift app, and the concrete conventions
now live under `.trellis/spec/macos/`. The thinking guides in
`.trellis/spec/guides/` are kept as-is — they are language-neutral.

The below checklist is what the bootstrap task was tracking, mapped
to its current home.

---

## Original checklist

- [x] Fill backend guidelines — **done**. `.trellis/spec/macos/persistence.md`
      (SQLite schema, queue model, two time bases, three pruning paths).
- [x] Fill frontend guidelines — **done**. `.trellis/spec/macos/swiftui-conventions.md`
      (`@StateObject` vs `@ObservedObject`, accent scope, AppKit bridge
      rules, lineLimit + minimumScaleFactor recipe).
- [x] Add code examples — **done**. Every macos/ guide anchors its
      rules on real file paths in the codebase.

---

## What got filled (current locations)

| Concern | Where it lives |
| --- | --- |
| Project layout, target wiring | `.trellis/spec/macos/project-layout.md` |
| SwiftUI / state-object / accent / bridge rules | `.trellis/spec/macos/swiftui-conventions.md` |
| Combine / `@Published` / sink traps | `.trellis/spec/macos/combine-pitfalls.md` |
| Localization (`Loc`, date order, sentinel) | `.trellis/spec/macos/localization.md` |
| SQLite / two time bases / three prune paths | `.trellis/spec/macos/persistence.md` |
| When to think across layers / reuse code | `.trellis/spec/guides/index.md` |
| Combine pitfalls with longer code examples | `.trellis/spec/guides/swift-combine-swiftui-pitfalls.md` |
| Trellis agent preamble | `.trellis/agents/implement.md`, `.trellis/agents/check.md` |

The top-level entry point is `.trellis/spec/index.md` — agents
read it first.

---

## How to archive this task

After all spec files are reviewed and the agent preamble points at
them correctly, the task can be archived:

```bash
python3 ./.trellis/scripts/task.py finish
python3 ./.trellis/scripts/task.py archive 00-bootstrap-guidelines
```

No branch was tracked for this task (it is documentation-only and
predates the local git workflow), so use `--skip-branch-validation`.
