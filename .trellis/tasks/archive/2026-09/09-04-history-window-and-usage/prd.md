# History window and usage features — PRD (retrospective, 2026-09)

> **This task predates 0.3.0.** The PRD body was written from a
> forward-looking "what should we build" angle and never filled in
> (the "Requirements" and "Acceptance Criteria" sections read "TBD"
> when the repo was set up). Everything it asks for has since shipped
> — see `design.md` and `implement.md` for what was actually built
> under each bullet. This PRD is preserved here as a record of
> intent; the **acceptance criteria** below reflect the shipped
> behaviour, not the original TBD.

## Goal (verbatim from the original task)

> 这一组能力围绕历史窗口与使用量统计展开：完整历史热力图、程序知识库、
> 数据导出、菜单栏切换、配额/异常上传提醒、接口类型过滤（用户态
> nettop 可实现部分）。

Six capabilities. The first five shipped; the sixth (process
knowledge base) was descoped.

## Scope-by-capability, mapped to what shipped

| Original bullet | Shipped under |
| --- | --- |
| 完整历史热力图（full heatmap） | `FlowTrace/Feature/History/HistoryHeatmapView.swift` + `HistoryHeatmapModel.swift`, exposed as the "Network heatmap" tab in `HistoryWindowView`. |
| 数据导出（CSV / JSON） | `FlowTrace/Feature/History/CSVExporter.swift` — CSV only; JSON was descoped because the existing CSV is openable in any spreadsheet and adding JSON would have added another code path with no consumer. |
| 菜单栏切换（menu bar segments） | `FlowTraceForMac/StatusBarView.swift` — daily (`D`) and period (`P`) segments toggleable from Settings → General. |
| 配额提醒（quota alerts） | `FlowTrace/Feature/Usage/QuotaMonitor.swift` — local notifications at 80/100% (and a custom threshold), once per period per threshold. |
| 异常上传提醒（abnormal upload alerts） | `FlowTrace/Feature/Usage/ProcessAlertMonitor.swift` — per-process 7-day median × multiplier, dedup via `process_alert` unique index. |
| 接口类型过滤（interface category filter） | `FlowTrace/Feature/Interface/` — Wi-Fi / Wired / Local Direct / Other buckets; the popover summary at the bottom of `ContentView`. |
| 程序知识库（process knowledge base） | **Not built.** `FlowTrace/Feature/Localization/` exists, but no in-app knowledge base was added — the project kept its dependency-free, no-network stance and could not host a curated knowledge base. |

## Acceptance criteria (post-shipment)

- [x] Heatmap data source: `interface_minute` aggregated by local hour bucket.
- [x] Heatmap supports category filter (all on = sum of all interfaces, any subset = filtered subset).
- [x] Heatmap cross-midnight cells split into the correct local day (`HistoryHeatmapPersistenceTests.testLocalMidnightSplitsIntoDifferentDayCells`).
- [x] CSV exports timestamped rows with a stable schema, three categories: process, interface, alert. See `CSVExporter.swift`.
- [x] Menu bar `D` and `P` segments respect Settings → General toggles.
- [x] Quota thresholds: 80% and 100% always; an optional custom percent merges in; per-period dedup keys (`<periodStartISO>:<threshold>`) survive restarts; first observation in a period does not fire.
- [x] Process alerts: 7-day median × multiplier and an absolute MB floor; daily dedup via `process_alert` unique index `(day, name_key, direction)`.
- [x] Interface overview: Wi-Fi / Wired / Local Direct / Other, "today" cumulative bytes shown next to each bucket, live updates from `InterfaceModel`.

## Out of scope

- **Process knowledge base** — explicitly descoped (see table).
- **Network requests of any kind** — `AGENTS.md` forbids them; a network-hosted knowledge base would have violated that.

## Constraints

- No third-party dependencies (Codable + system SQLite only).
- No new entitlements; the file stays the empty `<dict/>`.
- Every change here is also documented under `AGENTS.md` → "Active
  experiments" with the touched files.

## References

- Implementation log: `implement.jsonl`
- Self-check log: `check.jsonl`
- Technical design: `design.md`
- Execution plan: `implement.md`
- Release notes: `changelog/0.3.0.md` (every milestone corresponds to one or more of the bullets above)
- Architecture overview: `docs/ARCHITECTURE.md`