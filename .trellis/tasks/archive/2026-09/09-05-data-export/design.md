# CSV data export — Design (retrospective, 2026-09)

## One file, three shapes

`CSVExporter` is a single `enum` with three `static func` writers
and one `static func save` that drives `NSSavePanel`. The three
writers share an escape helper and a `timeFormatter`. This shape was
chosen over three separate classes because:

- All three emit CSV with the same escaping rules, the same
  timestamp format, and the same `NSSavePanel` workflow. A class
  hierarchy would add ceremony for no behavioural gain.
- The writers are pure (`(rows) -> String`) — trivial to test in
  isolation; see `CSVExporter.processCSV` / `interfaceCSV` / `alertCSV`.

## Output shape per dimension

| Tab | Shape | Function | Source |
| --- | --- | --- | --- |
| Heatmap / interface history | `Time, Interface, Download (bytes), Upload (bytes)` | `CSVExporter.interfaceCSV(_:)` | `interface_minute` rows within the selected range |
| App usage | `Time, Process, Download (bytes), Upload (bytes)` | `CSVExporter.processCSV(_:)` | `process_usage` rows within the selected range |
| Alert log | `Time, Process, Direction, Today (bytes), Median 7d (bytes), Factor` | `CSVExporter.alertCSV(_:)` | `AlertLogModel.records` (already in memory) |

The "Time" column is `yyyy-MM-dd HH:mm:ss`. For per-minute data
(`process_usage`, `interface_minute`) the timestamp is the bucket's
ISO date; for alert records it is the record's date.

## Bytes as numbers, unit in the header

Bytes are written as plain integers (e.g. `1523048`), with the
unit (`bytes`) stated in the column header. This means a
spreadsheet can sum or chart the column directly without
formatting tricks. It also means the schema is stable across
locales — a German user opening the CSV sees the same numbers as
a Chinese user.

## Escaping

A field is wrapped in double quotes if it contains a comma, a quote,
a newline, or starts/ends with whitespace. Inner double quotes are
doubled. This is RFC 4180.

## Save panel

```swift
NSSavePanel().beginSheetModal(for: window) { response in
    guard response == .OK, let url = panel.url else { return }
    try? csv.write(to: url, atomically: true, encoding: .utf8)
}
```

The panel's `nameFieldStringValue` is pre-populated with
`<kind>-<fromISO>_<toISO>.csv` so the user does not have to think
about a filename. Sheet-modal attachment is used so the dialog
parents to the history window — without it, the dialog would float
loose over the popover and look broken.

## Why no streaming

The first version buffered the full result set in memory before
writing. For a 30-day window of `interface_minute` at one row per
minute per category (4 categories × 60 minutes × 24 hours × 30 days
= ~170 K rows max, but typically much less once you drop empty
buckets), the in-memory size is well under 10 MB. Streamed reads
through `sqlite3_step` were considered but never landed because:

1. The bottleneck is `NSSavePanel.runModal()`, not the read.
2. The CSV writer is single-pass and trivially serial; a streaming
   read would only complicate the call site.

If the window grows to a year, revisit: the optimization is
unblocked once the read pipeline exposes a `ResultSet` iterator.

## Why no JSON

JSON has no consumer in the app:

- The heatmap, app-usage, and alert-log views render from
  in-memory structs (`HeatmapCell`, `ProcessUsageSummary`,
  `AlertRecord`), not from JSON.
- Exporting JSON would mean defining a parallel schema, writing a
  parallel writer, and writing a parallel importer — none of which
  any user has asked for.
- A user wanting JSON can pipe the CSV through `jq`: it works.

If a future feature wants machine-readable consumption (e.g. a
script), add a JSON sibling at that point. The current CSV is not
the constraint.

## What machine-facing timestamps buy us

`yyyy-MM-dd HH:mm:ss` (lexicographic = chronological) means the
file is sortable as text, and stable across locales. This is the
*one* place a fixed `dateFormat` is correct: this is a
machine-facing timestamp, not a user-facing one. See
`.trellis/spec/macos/localization.md` § "What is and is not
localized" for the policy.

## Where the call sites live

`HistoryHeatmapView`, `AppUsageView`, `AlertLogView` each have an
"Export" button that calls the relevant `model.exportCSV()`
function, which writes to a temp file and opens the save panel
inside `CSVExporter.save(...)`. The user-facing string "Export" is
already localizable via `Loc.l("Export")` (same string as the
menu-bar's quota period total).

## Self-check

There are no dedicated CSV unit tests in the repo today. The
acceptance criteria above are verified manually: open the file in
Numbers, verify the columns and the byte counts. The next time
someone touches `CSVExporter`, adding `CSVExporterTests.swift` is
the natural follow-up (file is small, pure-function friendly).
