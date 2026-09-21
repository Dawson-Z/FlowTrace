# History window and usage features — Implementation plan (retrospective, 2026-09)

Each bullet below is one research milestone (a single shippable
unit, one commit on `main`, one entry in `changelog/0.3.0.md`).
Ordered chronologically by ship date.

## Milestone 0.3.0 #1 — In-memory history ring buffer

- Added `RingBuffer` (fixed capacity, O(1) append), `HistoryStore`
  (the popover sparkline data source), `HistoryView` (the 60-sample
  sparkline drawn with raw `Path`).
- `Network.swift` pushes frames into `HistoryStore`.
- `ContentView.swift` hosts the view at the bottom of the popover.
- **Why milestone 1**: the ring buffer is a prerequisite for every
  later persistence-based feature. Without it, there is no "live
  history" to extend into "persistent history" in milestone 4.

## Milestone 0.3.0 #2 — Refactor: `print` → `Logger`, GB tier

- `FlowTrace/Feature/Logging/AppLogger.swift` + `LogHelpers.swift`.
- New `os.Logger` subsystem `local.FlowTrace` with seven categories.
- `Utils.formatBytes` gained the GB tier (was missing — `1024.0 MB/s`
  before).
- `@ObservedObject` → `@StateObject` migration where it matters.
- **Not user-visible**, but every later milestone depends on
  `Log.persistence` / `Log.settings` for traceable self-checks.

## Milestone 0.3.0 #4 — SQLite persistence

- `FlowTrace/Feature/History/HistoryPersistence.swift` —
  `import SQLite3`, single file, single connection, WAL + NORMAL,
  one row per nettop frame in `history(id, ts, in_bps, out_bps)`.
- `HistoryStore.bootstrap()` seeds the ring buffer from disk.
- Settings → Storage gains the retention knob (`historyRetentionDays`).
- **Why milestone 4**: persistence is the prerequisite for the
  heatmap, the alert log, and the CSV exports. Without it the
  history window has no data to show beyond the live ring buffer.

## Milestone 0.3.0 #8 — History statistics

- `HistoryPersistence.summary(dayStart:completion:)` —
  two indexed SQL aggregates: today's peak bytes and 24-hour mean.
- `HistoryStore.summary` republishes (refreshed every frame,
  de-duped against the published value).
- `HistoryView` shows the new `Today peak` / `24h avg` row.
- **Why milestone 8**: numbers belong with the curve, not in a
  separate UI. Once summary is here, the alert log and heatmap can
  reuse the same `HistoryStore.summary` plumbing.

## Milestone 0.3.0 #9 — Interface dimension

- `FlowTrace/Feature/Interface/` (5 files): `InterfaceMonitor`
  (second independent `nettop` subprocess, socket mode),
  `InterfaceClassifier`, `InterfaceMinuteAggregator`, `InterfaceModel`,
  `InterfaceSummaryView`.
- Popover gains a stacked share bar + per-bucket "today" byte
  count.
- The two `nettop` subprocesses (`-P` for processes, plain socket
  mode for interfaces) keep `-t external` so loopback is excluded.
- **Why milestone 9**: the heatmap reads `interface_minute`, which
  is built by `InterfaceMinuteAggregator`. Without this milestone
  there is no category axis for the heatmap.

## Milestone 0.3.0 #13 — History window: heatmap + interface history

- New `interface_history` table (per-frame per-category).
- `HistoryPersistence.interfaceMinuteHeatmap` (the SUM-by-hour query).
- `HistoryHeatmapView` with two directions: day-as-row and
  day-as-column (GitHub style).
- Range presets (Today / 7d / 30d) + custom date bounds.
- New standalone history window (`AppDelegate.showHistoryWindow`).
- **Why milestone 13**: this is the first time the user can see
  *anything* about external traffic over time, in a non-popover
  surface. CSV export, alert log, and the settings-window polish
  all build on top of this milestone.

## Milestone 0.3.0 #14 — App usage tab (per-process usage history)

- New `process_usage` minute table; pre-aggregated, not per-frame
  (would have been ~1.3 M rows/day otherwise).
- `ProcessUsageAggregator` accumulates per-minute `bytes = Σrate × interval`.
- Grouping key: lowercased process name (so quit/relaunched processes
  accumulate under one row, and same-name Electron helpers merge).
- New "App usage" tab in the history window.
- **Why milestone 14**: this is the first place a non-developer can
  see per-process historical usage. The alert log and quota monitor
  both depend on the same `process_usage` table.

## Milestone 0.3.0 #15 — Quota alerts + menu-bar totals

- `FlowTrace/Feature/Usage/UsageAggregator.swift` (shared period integrator).
- `FlowTrace/Feature/Usage/QuotaMonitor.swift` (the threshold / dedup layer).
- Menu-bar `D` and `P` segments with on / off toggles in Settings → General.
- **Why milestone 15**: period totals are also the menu-bar's data
  source, so this milestone ships both the visible segment and the
  notification layer.

## Milestone 0.3.0 #16 — Abnormal upload alerts

- `FlowTrace/Feature/Usage/ProcessAlertMonitor.swift`.
- New `process_alert` table, unique index `(day, name_key, direction)`.
- Notification authorization on Settings → Alerts toggle-on.
- **Why milestone 16**: by this point the data pipeline
  (`process_usage`) is mature, and the user has a way to tune the
  threshold. The alert log surface in the history window is added
  in a follow-up milestone so users can see what fired and tune.

## Milestone 0.3.0 #17 — Accent colour

- `FlowTrace/Feature/Appearance/AccentColor.swift` — manager,
  `.appAccentScope`, `AccentHexField`.
- Watches the system accent via the distributed
  `AppleColorPreferencesChangedNotification`.
- **Why milestone 17**: every later SwiftUI root needs the scope.
  Deferring it would have meant retrofitting every pane.

## Milestone 0.3.0 #18/22 — Settings window + hand-drawn tab bar

- `FlowTraceForMac/SettingsView.swift` was later split into
  `SettingsView.swift` + `SettingsComponents.swift` + 5× `Settings*Pane.swift`
  (see `archive/2026-09/09-04-localization/implement.md` for the
  refactor that came after).
- Plain `NSWindow`, one `NSHostingController` per pane.
- **Why milestones 18 → 22**: 18 was the first attempt
  (`NSTabViewController`'s toolbar tabs); 22 rewrote the tab bar by
  hand to avoid AppKit's "system accent tints the selected tab's
  icon and label" behaviour. Both milestones are documented as
  one bullet here because they are the same feature, just with a
  detour in the middle.

## Milestone 0.3.0 #19 — Accent-completeness pass

- `FlowTrace/Feature/Appearance/AccentControls.swift` —
  `AccentTextField`, `AccentPicker`, `AccentDateField`, `AccentTimeField`.
- Discovered two non-obvious correctness requirements:
  `controlTextDidBeginEditing` is **not** called by a click that
  only puts the caret in the field, and writing back through a
  `@Binding` from `dismantleNSView` aborts the process. Both have
  pinned code paths in AGENTS.md.

## Cross-cutting decisions (apply to multiple milestones)

- **One `nettop` per concern.** The process run and the
  interface run are independent subprocesses, not one
  multi-purpose run. Failure of one does not break the other.
- **One SQLite file, one connection, one serial queue.** Every
  table is on the same connection so WAL is coherent.
- **One `SharedStore`** for cross-module state (`FlowTraceForMac/Store.swift`).
  Modules publish through it; they do not import each other.
- **All date / number formatting goes through `Loc.dateFormatter`** —
  see `.trellis/spec/macos/localization.md`.

## Self-check rules (cross-cutting)

Every milestone ships a corresponding entry in `FlowTraceTests/`. The
list at the time of writing:
- `ListViewModelSortTests`, `ListViewModelMergeTests`
- `QuotaMonitorTests`
- `ProcessUsageAggregatorTests`
- `HistoryHeatmapPersistenceTests`
- `LocalizationTests`
- `AccentDateFieldTests`

New code paths get new tests in the same change; the
`trellis-check` agent preamble (`.trellis/agents/check.md`) lists
the macOS-specific false-positives to ignore.
