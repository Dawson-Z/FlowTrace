//
//  macOS / persistence.md
//  FlowTrace — Trellis spec
//
//  SQLite-backed persistence: schema, threading model, the two
//  time bases, and the three distinct pruning paths. Anything that
//  writes to `history.sqlite3` must respect these or data will
//  desync.
//

# Persistence (`HistoryPersistence`)

## Location

`<App Support>/FlowTrace/history.sqlite3` (system-managed;
`HistoryPersistence.defaultDbURL()`). One-time rename migration
moves the legacy `iTrafficPlus/` folder if present.

## Threading

```swift
// FlowTrace/Feature/History/HistoryPersistence.swift
private let queue = DispatchQueue(label: "history-persistence", qos: .utility)
// All sqlite3_* calls run on `queue`; the main thread never touches the handle.
```

| Direction | How it goes |
| --- | --- |
| Write (`append(...)`, `appendInterface(...)`, `appendInterfaceMinute(...)`, `appendProcessUsage(...)`, `appendProcessAlert(...)`) | Returns immediately; write happens on `queue`. |
| Async read | `queue.async { ... DispatchQueue.main.async { completion(...) } }`. |
| Synchronous read | Only `recent(limit:)` (used by `HistoryStore.bootstrap()` at launch, indexed, bounded). |

When testing, drive the queue to settle by waiting on the
completion. The pattern in
`ProcessUsageAggregatorTests.processUsage(in:fromBucket:toBucket:timeout:)`:

```swift
var loaded: [ProcessUsageSummary] = []
let deadline = Date().addingTimeInterval(timeout)
repeat {
    let done = expectation(description: "processUsage")
    persistence.processUsage(...) { rows in loaded = rows; done.fulfill() }
    wait(for: [done], timeout: timeout)
    if !loaded.isEmpty { break }
    Thread.sleep(forTimeInterval: 0.02)
} while Date() < deadline
return loaded
```

is the standard harness for queue-driven assertions.

## Two time bases — never mix them

| Column | Unit | Tables that use it |
| --- | --- | --- |
| `ts` | epoch-ms (Int64) | `history`, `interface_history`, `process_alert.ts` |
| `minute_bucket` | **local minute ordinal** | `process_usage`, `interface_minute` |

`minute_bucket` is computed as:

```swift
static func bucket(of date: Date) -> Int {
    let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
    return Int((Int64(date.timeIntervalSince1970 * 1000) + tzMs) / 60000)
}
```

Three things follow from this:

1. **Cross-midnight buckets are different days, not the same
   bucket with a different label.** A timestamp 1 s before local
   midnight belongs to the *previous* day's hour 23.
2. The query range for `minute_bucket` tables must be converted
   the same way — see `interfaceMinuteHeatmap` for the
   `(fromMs + tzMs) / 60000 → toBucket` form.
3. The hour bucket in `HeatmapCell` is `minute_bucket / 60`,
   the local day is `minute_bucket / (60 * 24)`.

The error mode for getting this wrong is the same family as the
`setLocalizedDateFormatFromTemplate` order trap: data is **silent
and structured correctly**, just off by one day or hour. There is
no error message to grep for.

## Schema (as of 2026-09)

```sql
CREATE TABLE history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,           -- epoch-ms
    in_bps INTEGER NOT NULL,
    out_bps INTEGER NOT NULL
);
CREATE INDEX idx_history_ts ON history(ts);

CREATE TABLE interface_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,           -- epoch-ms
    category TEXT NOT NULL,
    in_bps INTEGER NOT NULL,
    out_bps INTEGER NOT NULL
);
CREATE INDEX idx_iface_ts_cat ON interface_history(ts, category);

CREATE TABLE interface_minute (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    minute_bucket INTEGER NOT NULL, -- local minute ordinal
    category TEXT NOT NULL,
    in_bytes INTEGER NOT NULL,
    out_bytes INTEGER NOT NULL
);
CREATE INDEX idx_ifmin_bucket_cat ON interface_minute(minute_bucket, category);

CREATE TABLE process_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    minute_bucket INTEGER NOT NULL,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL,
    in_bytes INTEGER NOT NULL,
    out_bytes INTEGER NOT NULL
);
CREATE INDEX idx_pu_minute ON process_usage(minute_bucket);

CREATE TABLE process_alert (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    day INTEGER NOT NULL,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL,
    direction TEXT NOT NULL,
    today_bytes INTEGER NOT NULL,
    baseline_bytes INTEGER NOT NULL,
    multiplier REAL NOT NULL,
    ts INTEGER NOT NULL
);
CREATE UNIQUE INDEX idx_alert_unique ON process_alert(day, name_key, direction);
```

`process_alert`'s **unique index** is the dedup story for abnormal-
traffic alerts: "at most one alert per process per direction per
local day, even across restarts." Don't remove or relax it.

## Three distinct pruning paths

Each has a different table coverage. Do not unify them.

| Path | When | Coverage |
| --- | --- | --- |
| `prune()` | Once in `init`. | `history`, `interface_history`, `process_usage`, `interface_minute`. **Not** `process_alert`. |
| `pruneExpired(cutoffMs:cutoffBucket:)` / `expiredRowCount(...)` | Daily checkpoint (`DataRetentionController`). | `history`, `interface_history`, `process_alert` (by `ts`); `process_usage`, `interface_minute` (by `minute_bucket`). |
| `deleteRange(fromMs:toMs:fromBucket:toBucket:)` / `countRange(...)` | User "Clear range" from Settings → Storage. | Four tables, no `process_alert` (the alert log is not cleared by range). |

`clearAllTables` (clears every row from every table) was removed
when the Settings UI stopped calling it; the same effect is now
done by `deleteRange` over the full epoch. If you find yourself
wanting it back, prefer deleting the file via `defaultDbURL()` and
recreating — that also clears the unique-index dedup state.

## Bytes per second vs bytes

`history` and `interface_history` are **rates** (`in_bps`,
`out_bps`). `interface_minute` and `process_usage` are **byte
totals** (`in_bytes`, `out_bytes`).

Two reasons:

- The per-frame write rate is naturally normalized at
  `Network.parser`. Dividing by `interval` once at parse time
  produces `inBytesPerSec`, and writing that as a rate keeps the
  frame data dense (one row per second) and the schema small.
- Aggregation into the minute tables multiplies rate × interval
  to get bytes for the bucket. The multiply happens **only** at
  `ProcessUsageAggregator.flushLocked` /
  `InterfaceMinuteAggregator.flush` — never in the query layer.

For `interface_history`'s "today" computation, the query is
`SUM(rate) × interval`; for `interface_minute`, the values are
already bytes. Don't mix them up.

## Retention defaults

Default retention is **7 days** (`HistoryPersistence.init(dbURL:retentionSeconds:)`).
The launch path overrides it with the user's setting:

```swift
let retention = TimeInterval(SettingsStore.shared.historyRetentionDays) * 24 * 3600
HistoryPersistence(dbURL: .defaultDbURL(), retentionSeconds: retention)
```

Settings → Storage allows 1 to ~36500 days (≈100 years). The
current default in `SettingsStore` is 30.

## Migrations

There are no migration steps yet — adding a column requires a
hand-written `ALTER TABLE` block in `createSchemaIfNeeded()`. If
you add one, gate it on `PRAGMA user_version` so existing installs
don't re-apply it:

```sql
PRAGMA user_version; -- 0 on fresh installs, bump on every schema change
```

…and update the version after each successful migration. Keep
migrations additive (add columns, never drop or rename) so the
file format stays forward-compatible.