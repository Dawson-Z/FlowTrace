//
//  HistoryPersistenceModels.swift
//  FlowTrace — Feature/History
//
//  The value types HistoryPersistence reads and writes: one struct per
//  SQLite table, plus the heatmap cell and the two rendered types the
//  history window consumes.
//

import Foundation

/// One row in the `history` table.
struct HistoryRow {
    let ts: Int64              // ms since epoch
    let inBytesPerSec: Int
    let outBytesPerSec: Int
}

/// One row in the `interface_history` table: per-`InterfaceCategory` rates
/// for a single frame.
struct InterfaceHistoryRow {
    let ts: Int64              // ms since epoch
    let category: String       // InterfaceCategory.rawValue (stable across locales)
    let inBytesPerSec: Int
    let outBytesPerSec: Int
}

/// One heatmap cell: the cumulative in/out *bytes* over one local hour bucket.
/// Bytes are SUM(rate) × sample interval — the same frame-by-frame sum the
/// totals table and the period totals use, so the heatmap agrees with the
/// menu-bar / popover totals instead of estimating rate × 3600.
/// `day` is the local day count since 1970-01-01 (day = bucket / 24 after
/// applying the timezone offset), `hour` the local hour (bucket % 24).
struct HeatmapCell: Equatable {
    let day: Int
    let hour: Int
    let inBytes: Int
    let outBytes: Int
}

/// Aggregated per-process usage over a queried range: SUM(bytes) GROUP BY
/// name_key, display name via MAX(name).
struct ProcessUsageSummary: Equatable {
    let name: String
    let inBytes: Int
    let outBytes: Int
}

/// One flush unit into `process_usage` (see ProcessUsageAggregator).
struct ProcessUsageFlushRow {
    let minuteBucket: Int
    let name: String
    let nameKey: String
    let inBytes: Int
    let outBytes: Int
}

/// One row in `process_alert`: a fired per-process traffic alert. The
/// unique index on (day, name_key, direction) enforces "at most one alert
/// per process per direction per local day" at the storage layer.
struct ProcessAlertRow {
    let day: Int              // local day ordinal (days since 1970, local)
    let name: String
    let nameKey: String
    let direction: String     // "in" / "out"
    let todayBytes: Int
    let baselineBytes: Int    // 7-day daily median
    let multiplier: Double    // todayBytes / baselineBytes (∞ encoded as 0)
    let ts: Int64             // ms since epoch
}

/// One rendered alert-log entry for the history window's alert tab.
struct AlertRecord: Equatable {
    let date: Date
    let name: String
    let isIn: Bool
    let todayBytes: Int
    let baselineBytes: Int
    let multiplier: Double
}
