# History window and usage features — Design (retrospective, 2026-09)

Each bullet below describes the architectural decision that shipped
for one of the PRD's capabilities. Where the shipped behaviour
diverges from the original forward-looking intent, this is
called out.

## 1. Heatmap — minute-cadence source

**Decision**: read `interface_minute` (not `history` / `interface_history`)
when the heatmap is opened. `interface_minute` is written per
category, per local minute ordinal. Summing by `minute_bucket / 60`
yields the local hour bucket directly.

**Why not `history` / `interface_history`?** Both store per-frame
rates, so a "all categories" aggregation would need to fold every
interface into one stream and lose category filtering. The minute
table is the right grain: it's already pre-summed per (minute,
category), and per-category grouping is `GROUP BY minute_bucket / 60`.

**Where**: `HistoryPersistence.interfaceMinuteHeatmap` (`HistoryPersistence+Queries.swift`),
aggregated in `HistoryHeatmapModel.reload()`.

**Cross-midnight handling**: a timestamp 1 s before local midnight
belongs to the **previous** day's hour 23. This is enforced by
the `(epochMs + tzMs) / 60000 → minute_bucket` conversion. Pinned
by `HistoryHeatmapPersistenceTests.testLocalMidnightSplitsIntoDifferentDayCells`.

## 2. CSV export — process / interface / alert, three shapes

**Decision**: one CSV file per export, three shapes behind one
`enum CSVExporter` with three `static func` writers:

- `processCSV(_:)` → `(timestamp, name, in_bytes, out_bytes)` over the
  app's `process_usage` minute data.
- `interfaceCSV(_:)` → `(timestamp, category, in_bytes, out_bytes)` over `interface_minute`.
- `alertCSV(_:)` → `(timestamp, name, direction, today_bytes, median_7d, factor)`.

**Why CSV only, not JSON?** JSON adds a second code path with no
consumers in the app (the heatmap and tables render from in-memory
structs, not from JSON), and CSV opens directly in Excel / Numbers.
Schema and unit are documented in the file header of `CSVExporter.swift`.

**Why stable timestamps?** `yyyy-MM-dd HH:mm:ss` lexicographic
order = chronological order, which is what spreadsheets assume.
This is the one place a *fixed* `dateFormat` is correct — it is a
machine-facing timestamp, not a user-facing one.

**Where**: `FlowTrace/Feature/History/CSVExporter.swift`,
invoked from the heatmap / app-usage / alert-log tab exports.

## 3. Menu-bar `D` / `P` segments — toggleable

**Decision**: render the two segments (`D` = today's bytes,
`P` = quota-period bytes) inside `StatusBarView`, controlled by
`SettingsStore.showTodayInMenuBar` / `showPeriodInMenuBar`. The
column width in `AppDelegate.statusBarLength` is computed from
those settings so the menu-bar item resizes when toggling.

**Why fixed columns?** The status item is too narrow to reflow;
a fixed layout avoids jitter on redraw.

**Where**: `FlowTraceForMac/StatusBarView.swift`, width math in
`AppDelegate.swift:statusBarLength`.

## 4. Quota alerts — threshold crossing + dedup

**Decision**: `QuotaMonitor` watches `UsageAggregator.$today/$week/$month`
via Combine. On every emission it calls a pure decision layer:

```
shouldFire(prev:current:threshold:key:alreadyFired:) -> Bool
    = (current >= threshold)
      && !alreadyFired.contains(key)
      && (prev < threshold)
```

Fires once per (period, threshold) crossing. Dedup keys
(`<periodStartISO>:<threshold>`) live in `UserDefaults`
(`quotaFiredKeys`) and re-arm automatically at period rollover
because the period-start ISO changes.

**Why a pure function?** Testability — the real monitor pulls
`@Published` values from three streams and notifies on fire, so
unit-testing the crossing rule needs the rule extracted. See
`QuotaMonitor.shouldFire` and the 18 test methods in
`QuotaMonitorTests.swift`.

**Why notify via `UNUserNotificationCenter`?** Because the menu-bar
app is `LSUIElement` and considered "active" most of the time. The
`UNUserNotificationCenterDelegate.willPresent` returns
`[.banner, .list, .sound]` from `AppDelegate`, so quota alerts pop
visibly instead of being silently routed to Notification Center.

**Where**: `FlowTrace/Feature/Usage/QuotaMonitor.swift`, request
authorization at `Settings → Quota` toggle-on (`QuotaMonitor.requestAuthorization()`).

## 5. Abnormal upload / download alerts — 7-day median

**Decision**: `ProcessAlertMonitor` maintains per-process rolling
7-day medians, read from `process_usage`. A direction fires when
**both** hold for the process:

- Cumulative bytes today ≥ the per-direction MB floor (default 500 MB).
- Cumulative bytes today ≥ `multiplier × median7day` (default ×10).

The threshold and floor are user-configurable in `Settings →
Alerts` (`alertUploadMultiplier`, `alertMinUploadMB`,
`alertDownloadMultiplier`, `alertMinDownloadMB`).

**Why 7 days, not 15 minutes?** The original `UploadAnomalyMonitor`
(milestone 16) used the last 15 frames, but that conflates "the
process is busy" with "the process is anomalous". A week-long
median is robust against daily cycles.

**Why two conditions, not one?** A brand-new process has no
median (treated as 0). With the floor alone, every fresh process
would trip. With the multiplier alone, a process whose baseline is
"almost zero" would alert on any non-zero traffic. Both together:
either the baseline shows real usage history, or the absolute
volume is enough to be unusual by itself.

**Where**: `FlowTrace/Feature/Usage/ProcessAlertMonitor.swift`;
the daily dedup lives in `process_alert`'s unique index
`(day, name_key, direction)` — the **storage layer** enforces
"at most one alert per (process, direction, local day)", even
across restarts.

## 6. Interface category filter — Wi-Fi / Wired / Local Direct / Other

**Decision**: `InterfaceClassifier` runs `networksetup -listallhardwareports` once at startup to map `Device → Hardware Port`, then classifies each socket-mode interface name as one of four categories:

- `awdl0` / `llw0` → Local Direct (peer-to-peer, AirDrop, etc.)
- `portByDevice[iface]` matches `Wi-Fi` → Wi-Fi
- `portByDevice[iface]` matches `USB*` / `Ethernet*` / `Thunderbolt*` → Wired
- Numeric `en*` → Wired (matches real `en*` devices not in the hardware-ports list)
- `bridge*` or unknown → Other

**Why not hard-coded interface names?** A hard-coded table cannot
work: dynamic virtual interfaces (`en13`, `bridge100`) never
appear in `networksetup`'s output. See the `InterfaceClassifier.swift`
file header.

**Where**: `FlowTrace/Feature/Interface/InterfaceClassifier.swift`,
category data flow through `InterfaceMonitor → InterfaceModel →
InterfaceSummaryView` (popover footer). The heatmap category
filtering is the **same classification** via
`InterfaceCategory.allCases`.

## 7. Process knowledge base — descoped

A curated knowledge base (e.g. "what does `nsurlsessiond` do,
can it be blocked?") was originally considered. **Descoped**:
- The project ships with no third-party packages and no network
  calls, so a knowledge base can only be a bundled JSON file.
- The locale-aware string tables already carry every label the
  app needs to render; a separate process-name knowledge base
  duplicates the role of system documentation.
- `AGENTS.md` forbids remote network calls; a hosted knowledge
  base would violate that.

The slot is still open: if a future contributor wants to add
one, it should live at `FlowTrace/Feature/Knowledge/ProcessKB.swift`
as a read-only `JSONDecoder`-loaded struct, no network.
