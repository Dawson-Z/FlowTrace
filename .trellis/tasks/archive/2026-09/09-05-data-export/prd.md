# CSV data export — PRD (retrospective, 2026-09)

> **This task predates 0.3.0.** The PRD body was written from a
> forward-looking "what should we build" angle. Everything it asks
> for in CSV form has since shipped; the JSON variant was descoped
> (see decision below). This PRD is preserved here as a record of
> intent; the **acceptance criteria** below reflect the shipped
> behaviour, not the original TBD.

## Goal (verbatim from the original task)

> 把本机数据导出为 CSV（或 JSON）。

## Scope, mapped to what shipped

| Original bullet | Status | Where |
| --- | --- | --- |
| 历史窗口工具栏加"导出"按钮 → `NSSavePanel` | ✅ Shipped. One button per tab. | `HistoryHeatmapView`, `AppUsageView`, `AlertLogView` — each tab's `model.exportCSV()` call site |
| CSV 维度：热力图 Tab | ✅ Shipped as `CSVExporter.interfaceCSV`. | `FlowTrace/Feature/History/CSVExporter.swift` |
| CSV 维度：程序用量 Tab | ✅ Shipped as `CSVExporter.processCSV`. | same file |
| CSV 维度：接口历史 | ✅ Shipped — `interfaceCSV` covers the heatmap source data. | same file |
| CSV：UTF-8 + BOM + RFC 4180 转义 | ✅ Shipped. | same file |
| JSON 导出 | ❌ **Descoped.** No consumer in the app; the existing CSV opens directly in any spreadsheet. Adding a parallel JSON code path with no user-visible payoff. | n/a |
| 流式分批读取 | ⚠️ **Partially shipped.** Reads are batched through the SQLite queue (`HistoryPersistence` writes and reads both go through `queue.async`), but the implementation loads the full result set into memory before writing to disk. 30-day exports are small enough (≤ ~2 MB for the heatmap source) that the streaming optimization never landed. | see "Open optimizations" in `implement.md` |
| 文件名含维度与范围 | ✅ Shipped (`<kind>-<from>_<to>.csv`). | `CSVExporter.save(csv:suggestedName:)` |
| 三语（按钮 / 成功 / 失败） | ✅ Shipped via `Loc.l(_:)`. | call sites above |

## Acceptance criteria (post-shipment)

- [x] **CSV opens correctly in Numbers / Excel** with a header row and
  the expected columns (`Time, Process, Download (bytes), Upload (bytes)`
  for process; `Time, Interface, Download (bytes), Upload (bytes)`
  for interface; `Time, Process, Direction, Today (bytes), Median 7d (bytes), Factor`
  for alert).
- [x] **Timestamps are stable** and lexicographic = chronological
  (`yyyy-MM-dd HH:mm:ss`).
- [x] **Suggested filename includes the export's dimensions**:
  `<kind>-<fromISO>_<toISO>.csv`.
- [x] **Cancellation is safe**: dismissing the save panel is a no-op
  (`NSSavePanel.runModal() == .cancel` returns early).
- [ ] *JSON output (originally proposed)* — descoped; see table.
- [ ] *Streaming read for very large windows* — not shipped; see
  `implement.md` "Open optimizations".

## Out of scope

- **JSON export** — descoped (no consumer; CSV is universal).
- **Scheduled auto-export** — not in this task.
- **iCloud sync / cloud round-trip** — explicitly forbidden by `AGENTS.md` ("No data leaves this machine").

## Constraints

- No third-party packages. CSV emission is hand-written; escaping
  follows RFC 4180 (commas, quotes, newlines inside fields).
- No new entitlements.
- The file lives under `FlowTrace/Feature/History/CSVExporter.swift`
  rather than a top-level module — it is one feature's output surface.

## References

- Implementation log: `implement.jsonl`
- Self-check log: `check.jsonl`
- Technical design: `design.md`
- Execution plan: `implement.md`
- Release notes: `changelog/0.3.0.md`
- Architecture overview: `docs/ARCHITECTURE.md`
