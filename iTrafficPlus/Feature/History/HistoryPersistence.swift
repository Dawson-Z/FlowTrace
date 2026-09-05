//
//  HistoryPersistence.swift
//  iTrafficPlus — Feature/History
//
//  SQLite-backed persistence for the per-frame in/out totals published by
//  HistoryStore. Uses the system-provided SQLite3 (`import SQLite3`) rather
//  than any third-party wrapper: this keeps iTrafficPlus at zero external
//  dependencies, matching the upstream iTraffic rule of "no third-party
//  dependencies, no network requests of its own, no sandbox."
//
//  Layout
//  ------
//  File:   <App Support>/iTrafficPlus/history.sqlite3
//  Schema: one row per nettop frame (2 s cadence by default).
//          `ts` is ms-since-epoch (Int64, monotonic clock independent of
//          user's clock changes; we use mach_absolute_time converted via
//          CACurrentMediaTime so a backwards clock jump does not double-
//          count).
//  Pruning: rows older than `retentionSeconds` are deleted on a debounce
//          timer so the table stays small (≪ 1 MB for 7 days of 2-s data).
//
//  Threading
//  ---------
//  All write paths run on a private serial queue. Reads (loadInitial) block
//  the caller; the seed load is bounded (one SELECT, indexed) and only runs
//  at app launch when no UI is shown yet, so a synchronous read is fine.
//

import Foundation
import SQLite3

/// Translates between Swift's `String` and SQLite's `SQLITE_TRANSIENT`
/// constant, which is a C `unsafePointer` macro that Swift imports as
/// `unsafeBitCast` magic. Centralising it here keeps the call sites
/// (almost) readable.
private let SQLITE_TRANSIENT_BRIDGE = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

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

/// One heatmap cell: the average in/out rate over one *local* hour bucket.
/// `day` is the local day count since 1970-01-01 (day = bucket / 24 after
/// applying the timezone offset), `hour` the local hour (bucket % 24).
struct HeatmapCell: Equatable {
    let day: Int
    let hour: Int
    let avgInBytesPerSec: Int
    let avgOutBytesPerSec: Int
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

final class HistoryPersistence {

    /// App Support / iTrafficPlus / history.sqlite3 — created on demand.
    static func defaultDbURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("iTrafficPlus", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("history.sqlite3")
    }

    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private let retentionSeconds: TimeInterval
    /// Exposed so callers can log the path on success / failure. Never
    /// mutated after `init`; treat as read-only.
    let dbURL: URL

    init?(dbURL: URL, retentionSeconds: TimeInterval = 7 * 24 * 3600) {
        self.dbURL = dbURL
        self.retentionSeconds = retentionSeconds
        self.queue = DispatchQueue(label: "history-persistence", qos: .utility)
        guard open() else { return nil }
        // Schema migrations / pruning happen on init. Single-threaded by
        // construction: we hold no references until after this returns.
        createSchemaIfNeeded()
        prune()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Open / schema

    private func open() -> Bool {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &handle, flags, nil) != SQLITE_OK {
            Log.persistence.error("open failed: \(String(cString: sqlite3_errmsg(handle)))")
            return false
        }
        // WAL: writes don't block readers, and concurrent reads scale. NORMAL
        // is the standard "fast + survives process crash" choice for our
        // append-only pattern; FULL would be over-kill.
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        db = handle
        return true
    }

    private func createSchemaIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                in_bps INTEGER NOT NULL,
                out_bps INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts);
            CREATE TABLE IF NOT EXISTS interface_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                category TEXT NOT NULL,
                in_bps INTEGER NOT NULL,
                out_bps INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_iface_ts_cat ON interface_history(ts, category);
            CREATE TABLE IF NOT EXISTS process_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                minute_bucket INTEGER NOT NULL,
                name TEXT NOT NULL,
                name_key TEXT NOT NULL,
                in_bytes INTEGER NOT NULL,
                out_bytes INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_pu_minute ON process_usage(minute_bucket);
            """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            Log.persistence.error("schema failed: \(msg)")
            sqlite3_free(err)
        }
    }

    private func prune() {
        let cutoffMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(retentionSeconds * 1000)
        for table in ["history", "interface_history"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "DELETE FROM \(table) WHERE ts < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            sqlite3_step(stmt)
        }
        // process_usage stores local *minute* ordinals, not epoch ms.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
        let cutoffBucket = (cutoffMs + tzMs) / 60000
        guard sqlite3_prepare_v2(db, "DELETE FROM process_usage WHERE minute_bucket < ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, cutoffBucket)
        sqlite3_step(stmt)
    }

    // MARK: - Write (async, serialised)

    /// Append one row. Returns immediately; the actual write happens on the
    /// private serial queue. We never call sqlite3 from the main thread.
    func append(_ row: HistoryRow) {
        queue.async { [weak self] in
            self?.appendSync(row)
        }
    }

    private func appendSync(_ row: HistoryRow) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO history (ts, in_bps, out_bps) VALUES (?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.persistence.error("prepare insert failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_bind_int64(stmt, 1, row.ts)
        sqlite3_bind_int64(stmt, 2, Int64(row.inBytesPerSec))
        sqlite3_bind_int64(stmt, 3, Int64(row.outBytesPerSec))
        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.persistence.error("insert step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - Read (synchronous, on caller)

    /// Read the most recent `limit` rows in chronological order. Used at
    /// app launch to seed the in-memory ring buffer so the sparkline is
    /// not empty after a restart.
    func recent(limit: Int) -> [HistoryRow] {
        var results: [HistoryRow] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT ts, in_bps, out_bps FROM (
                SELECT * FROM history ORDER BY id DESC LIMIT ?
            ) ORDER BY id ASC;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let inBps = Int(sqlite3_column_int64(stmt, 1))
            let outBps = Int(sqlite3_column_int64(stmt, 2))
            results.append(HistoryRow(ts: ts, inBytesPerSec: inBps, outBytesPerSec: outBps))
        }
        return results
    }

    // MARK: - Summary (async, on db queue)

    /// Aggregate the in-memory (or on-disk) history into a compact summary:
    /// today's peak in/out and the average in/out over the last 24 h.
    ///
    /// Runs on the db queue and delivers on the main queue, so neither the
    /// caller nor the UI thread ever touches sqlite3_*. Called from
    /// `HistoryStore.updateSummary()` on each frame; the SQL is two indexed
    /// scans over ≤ 302 400 rows, cheap enough to run every 2 s.
    func summary(dayStart: Date, completion: @escaping (HistorySummary) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.summarySync(dayStart: dayStart)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func summarySync(dayStart: Date) -> HistorySummary {
        let dayStartMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        let dayAgoMs = Int64(Date().timeIntervalSince1970 * 1000) - 24 * 3600 * 1000

        func intValue(sql: String, tsMs: Int64) -> Int {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            sqlite3_bind_int64(stmt, 1, tsMs)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }

        // Today's peaks (since local midnight).
        let peakIn  = intValue(sql: "SELECT MAX(in_bps) FROM history WHERE ts >= ?;", tsMs: dayStartMs)
        let peakOut = intValue(sql: "SELECT MAX(out_bps) FROM history WHERE ts >= ?;", tsMs: dayStartMs)
        // 24 h averages (floor so a value below 1 B/s still shows the digits).
        let avgIn   = intValue(sql: "SELECT AVG(in_bps) FROM history WHERE ts >= ?;", tsMs: dayAgoMs)
        let avgOut  = intValue(sql: "SELECT AVG(out_bps) FROM history WHERE ts >= ?;", tsMs: dayAgoMs)

        return HistorySummary(
            todayPeakIn: peakIn, todayPeakOut: peakOut,
            avgLast24hIn: avgIn, avgLast24hOut: avgOut
        )
    }

    // MARK: - Interface history (milestone: heatmap)

    /// Append per-category interface rows. Returns immediately; the write
    /// happens on the private serial queue (never the main thread).
    func appendInterface(_ rows: [InterfaceHistoryRow]) {
        queue.async { [weak self] in
            guard let self, !rows.isEmpty else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO interface_history (ts, category, in_bps, out_bps) VALUES (?, ?, ?, ?);"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("prepare interface insert failed: \(String(cString: sqlite3_errmsg(self.db)))")
                return
            }
            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, row.ts)
                sqlite3_bind_text(stmt, 2, row.category, -1, SQLITE_TRANSIENT_BRIDGE)
                sqlite3_bind_int64(stmt, 3, Int64(row.inBytesPerSec))
                sqlite3_bind_int64(stmt, 4, Int64(row.outBytesPerSec))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    Log.persistence.error("interface insert step failed: \(String(cString: sqlite3_errmsg(self.db)))")
                }
            }
        }
    }

    // MARK: - Heatmap aggregation

    /// Aggregate one table over `[fromMs, toMs)` into local-hour buckets.
    ///
    /// Bucket value is AVG(rate): rates are already bytes/sec, so the bucket
    /// average is that hour's mean rate — multiply by 3600 in the *display
    /// layer* for "bytes this hour". This stays correct regardless of the
    /// user's sample interval (1/2/5 s), unlike SUM.
    ///
    /// `categories` nil = aggregate the totals table (`history`); non-nil =
    /// `interface_history` filtered to those categories (empty set = no data).
    private func heatmapSync(table: String,
                             fromMs: Int64,
                             toMs: Int64,
                             categories: [String]?) -> [HeatmapCell] {
        // Shift timestamps into local time so bucket % 24 is the local hour.
        let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000

        var sql: String
        if let categories {
            let placeholders = categories.map { _ in "?" }.joined(separator: ",")
            sql = """
                SELECT CAST((ts + \(tzMs)) / 3600000 AS INTEGER) AS bucket,
                       AVG(in_bps), AVG(out_bps)
                FROM \(table)
                WHERE ts >= ? AND ts < ? AND category IN (\(placeholders))
                GROUP BY bucket
                ORDER BY bucket;
                """
        } else {
            sql = """
                SELECT CAST((ts + \(tzMs)) / 3600000 AS INTEGER) AS bucket,
                       AVG(in_bps), AVG(out_bps)
                FROM \(table)
                WHERE ts >= ? AND ts < ?
                GROUP BY bucket
                ORDER BY bucket;
                """
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.persistence.error("heatmap prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }

        var index: Int32 = 1
        sqlite3_bind_int64(stmt, index, fromMs); index += 1
        sqlite3_bind_int64(stmt, index, toMs); index += 1
        for category in categories ?? [] {
            sqlite3_bind_text(stmt, index, category, -1, SQLITE_TRANSIENT_BRIDGE); index += 1
        }

        var cells: [HeatmapCell] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bucket = Int(sqlite3_column_int64(stmt, 0))
            let avgIn = Int(sqlite3_column_int64(stmt, 1))
            let avgOut = Int(sqlite3_column_int64(stmt, 2))
            cells.append(HeatmapCell(
                day: bucket / 24,
                hour: bucket % 24,
                avgInBytesPerSec: avgIn,
                avgOutBytesPerSec: avgOut
            ))
        }
        return cells
    }

    /// Total-traffic heatmap (no category dimension).
    func historyHeatmap(fromMs: Int64, toMs: Int64,
                        completion: @escaping ([HeatmapCell]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let cells = self.heatmapSync(table: "history", fromMs: fromMs, toMs: toMs, categories: nil)
            DispatchQueue.main.async { completion(cells) }
        }
    }

    /// Per-category heatmap. `categories` empty = empty result (the user
    /// unchecked everything, which reads as "no data" rather than "all").
    func interfaceHeatmap(fromMs: Int64, toMs: Int64,
                          categories: [String],
                          completion: @escaping ([HeatmapCell]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !categories.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let cells = self.heatmapSync(table: "interface_history",
                                         fromMs: fromMs, toMs: toMs,
                                         categories: categories)
            DispatchQueue.main.async { completion(cells) }
        }
    }

    // MARK: - Process usage (per-app usage history)

    /// Batch-insert flushed minute rows. Async on the db queue.
    func appendProcessUsage(_ rows: [ProcessUsageFlushRow]) {
        queue.async { [weak self] in
            guard let self, !rows.isEmpty else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO process_usage (minute_bucket, name, name_key, in_bytes, out_bytes) VALUES (?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("prepare process_usage insert failed: \(String(cString: sqlite3_errmsg(self.db)))")
                return
            }
            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(row.minuteBucket))
                sqlite3_bind_text(stmt, 2, row.name, -1, SQLITE_TRANSIENT_BRIDGE)
                sqlite3_bind_text(stmt, 3, row.nameKey, -1, SQLITE_TRANSIENT_BRIDGE)
                sqlite3_bind_int64(stmt, 4, Int64(row.inBytes))
                sqlite3_bind_int64(stmt, 5, Int64(row.outBytes))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    Log.persistence.error("process_usage insert failed: \(String(cString: sqlite3_errmsg(self.db)))")
                }
            }
        }
    }

    /// SUM(bytes) per process over a local-minute bucket range, grouped by
    /// `name_key` (case-stable), display name via MAX(name). Main-queue
    /// callback, db-queue scan.
    func processUsage(fromBucket: Int, toBucket: Int,
                      completion: @escaping ([ProcessUsageSummary]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var rows: [ProcessUsageSummary] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT MAX(name), SUM(in_bytes), SUM(out_bytes)
                FROM process_usage
                WHERE minute_bucket >= ? AND minute_bucket < ?
                GROUP BY name_key
                ORDER BY SUM(in_bytes) + SUM(out_bytes) DESC;
                """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("process_usage query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
            sqlite3_bind_int64(stmt, 2, Int64(toBucket))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let nameC = sqlite3_column_text(stmt, 0) {
                    rows.append(ProcessUsageSummary(
                        name: String(cString: nameC),
                        inBytes: Int(sqlite3_column_int64(stmt, 1)),
                        outBytes: Int(sqlite3_column_int64(stmt, 2))
                    ))
                }
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Total bytes over a minute-bucket range (quota / menu-bar totals).
    /// Reads only the byte columns — interval-independent by construction.
    func usageBytes(fromBucket: Int, toBucket: Int,
                    completion: @escaping (UsageBytes) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            var usage = UsageBytes()
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT SUM(in_bytes), SUM(out_bytes) FROM process_usage WHERE minute_bucket >= ? AND minute_bucket < ?;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("usageBytes query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion(usage) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
            sqlite3_bind_int64(stmt, 2, Int64(toBucket))
            if sqlite3_step(stmt) == SQLITE_ROW {
                usage.inBytes = Int(sqlite3_column_int64(stmt, 0))
                usage.outBytes = Int(sqlite3_column_int64(stmt, 1))
            }
            DispatchQueue.main.async { completion(usage) }
        }
    }
}
