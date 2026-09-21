# CSV data export — Implementation plan (retrospective, 2026-09)

## Where this shipped

- `FlowTrace/Feature/History/CSVExporter.swift` — single file, four
  functions: `processCSV`, `interfaceCSV`, `alertCSV`, `save`.
- `FlowTrace/Feature/History/HistoryHeatmapModel.swift` —
  `exportCSV()` opens `exportInterfaceMinute(...)` and hands the
  rows to `CSVExporter`.
- `FlowTrace/Feature/History/ProcessUsageModel.swift` —
  `exportCSV()` pulls rows through `exportProcessUsage(...)` and
  hands them to `CSVExporter`.
- `FlowTrace/Feature/History/AlertLogModel.swift` — `exportCSV()`
  reads `process_alert` rows, formats in memory, hands them to
  `CSVExporter`.
- The save-panel `NSSavePanel` is driven by `CSVExporter.save` so
  every tab uses the same panel shape, the same suggested filename
  pattern (`<kind>-<fromISO>_<toISO>.csv`), and the same error
  handling.

## Order of milestones in 0.3.0

The export is a single milestone in `changelog/0.3.0.md`:

- **Milestone 13 — history window: heatmap + interface history.**
  This shipped `CSVExporter.interfaceCSV` together with the heatmap
  source data, because the user expects the data they just looked
  at to be exportable with one click.

The other two shapes (`processCSV`, `alertCSV`) landed in
milestones that added the corresponding tab:

- **Milestone 14 — App usage tab.** `processCSV` was added with it.
- **Milestone 16 — Abnormal upload alerts** (extended in a later
  patch with the alert log surface). `alertCSV` was added with the
  alert log tab in the history window.

The reason each shape shipped with its tab rather than as one big
"export" milestone: the export surface is invisible until the
tab it serves exists. Shipping them together kept each milestone
self-contained and reviewable.

## How an export call flows

```
HistoryHeatmapModel.exportCSV()
    → persistence.exportInterfaceMinute(fromBucket, toBucket) → rows
        [queued on persistence.queue, main-queue completion]
    → CSVExporter.interfaceCSV(rows) → String
        [pure]
    → CSVExporter.save(csv, suggestedName: "interface-…_….csv")
        → NSSavePanel.runModal() (sheet-modal on history window)
        → String.write(to: url, atomically: true, encoding: .utf8)
```

The user-visible flow is one click after the tab loads; no
intermediate screens.

## Constraints honored

- No third-party packages (Codable + system SQLite only).
- No new entitlements.
- Filename pattern uses `yyyy-MM-dd` (lexicographic) for the date
  range, matching the timestamps inside.
- UTF-8 (no BOM — Numbers and Excel both read UTF-8 without BOM in
  2024 versions; the original "UTF-8 with BOM" requirement was
  relaxed after testing).

## Open optimizations (not shipped)

1. **Streaming reads.** See `design.md` "Why no streaming".
2. **JSON sibling.** No consumer.
3. **Cancel via keyboard.** `NSSavePanel` accepts Escape by default
   on macOS, no work needed.
4. **Saved-as shortcut.** Out of scope: a "recently exported"
   history would be a future feature.

## Self-check

There are no unit tests for `CSVExporter` today. The acceptance
criteria above are verified manually. If a future contributor
touches this file, adding `CSVExporterTests.swift` is the natural
follow-up — it would be a pure-function suite (string in,
CSV string out) and would not need a real database.
