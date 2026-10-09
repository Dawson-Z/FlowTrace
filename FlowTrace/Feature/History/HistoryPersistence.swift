//
//  HistoryPersistence.swift
//  FlowTrace — Feature/History
//
//  SQLite-backed persistence for the per-frame in/out totals published by
//  HistoryStore. Uses the system-provided SQLite3 (`import SQLite3`) rather
//  than any third-party wrapper: this keeps FlowTrace at zero external
//  dependencies, matching the upstream iTraffic rule of "no third-party
//  dependencies, no network requests of its own, no sandbox."
//
//  Layout
//  ------
//  File:   <App Support>/FlowTrace/history.sqlite3
//  Schema: five tables (see createSchemaIfNeeded). `history` and
//          `interface_history` hold one row per sample frame (1 s cadence)
//          and key on `ts`, an epoch-ms Int64. `process_usage` and
//          `interface_minute` hold pre-aggregated rows keyed on a *local
//          minute ordinal* (minute_bucket), and `process_alert` keys on a
//          local day. Never mix the two time bases.
//  Pruning: three separate paths with different table coverage — `prune()`
//          runs once in init over the four history tables (not
//          `process_alert`), DataRetentionController's daily checkpoint
//          calls `pruneExpired` / `expiredRowCount`, and the user can
//          trigger `deleteRange` from Settings.
//
//  Threading
//  ---------
//  All write paths run on a private serial queue. Reads are dispatched to
//  that queue and delivered on the main queue; the only synchronous read is
//  `recent(limit:)`, whose seed load is bounded (one SELECT, indexed) and
//  only runs at app launch when no UI is shown yet, so blocking is fine.
//

import Foundation
import SQLite3

/// Translates between Swift's `String` and SQLite's `SQLITE_TRANSIENT`
/// constant, which is a C `unsafePointer` macro that Swift imports as
/// `unsafeBitCast` magic. Centralising it here keeps the call sites
/// (almost) readable.
///
/// Internal, not private: HistoryPersistence+Queries.swift binds text in
/// `interfaceMinuteHeatmap`, so the constant has to cross the file.
/// Same module and same app target — nothing leaks outside.
let SQLITE_TRANSIENT_BRIDGE = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

final class HistoryPersistence {

    /// App Support / FlowTrace / history.sqlite3 — created on demand.
    static func defaultDbURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("FlowTrace", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("history.sqlite3")
    }

    // Internal, not private: the read queries in
    // HistoryPersistence+Queries.swift share this one handle and the one
    // serial queue. Same module and same app target — nothing leaks outside.
    var db: OpaquePointer?
    let queue: DispatchQueue
    private let retentionSeconds: TimeInterval
    /// Exposed so callers can log the path on success / failure. Never
    /// mutated after `init`; treat as read-only.
    let dbURL: URL

    init?(dbURL: URL, retentionSeconds: TimeInterval = 7 * 24 * 3600) {
        self.dbURL = dbURL
        self.retentionSeconds = retentionSeconds
        self.queue = DispatchQueue(label: "history-persistence", qos: .utility)
        guard open() else { return nil }
        // Schema migrations happen on init. Single-threaded by
        // construction: we hold no references until after this returns.
        createSchemaIfNeeded()
        // NOTE: retention is *not* enforced here. Pruning at init ignored the
        // user's cleanup mode and silently deleted every overdue row on each
        // launch, which made the "notify before manual cleanup" mode remove
        // data it had promised only to remind about (found 2026-10-09). The
        // single policy owner is DataRetentionController: automatic mode
        // deletes at the daily checkpoint; manual-notification never deletes.
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
            CREATE TABLE IF NOT EXISTS interface_minute (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                minute_bucket INTEGER NOT NULL,
                category TEXT NOT NULL,
                in_bytes INTEGER NOT NULL,
                out_bytes INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_ifmin_bucket_cat ON interface_minute(minute_bucket, category);
            CREATE TABLE IF NOT EXISTS process_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                minute_bucket INTEGER NOT NULL,
                name TEXT NOT NULL,
                name_key TEXT NOT NULL,
                in_bytes INTEGER NOT NULL,
                out_bytes INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_pu_minute ON process_usage(minute_bucket);
            CREATE TABLE IF NOT EXISTS process_alert (
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
            CREATE UNIQUE INDEX IF NOT EXISTS idx_alert_unique ON process_alert(day, name_key, direction);
            """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            Log.persistence.error("schema failed: \(msg)")
            sqlite3_free(err)
        }
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

    // MARK: - Retention cleanup (scheduled checkpoint)

    /// Delete every row older than the retention cutoff and report the total
    /// number deleted (for the auto-cleanup log line). Delivers on main.
    func pruneExpired(cutoffMs: Int64, cutoffBucket: Int,
                      completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(0) }; return }
            let deleted = self.removeExpiredSync(cutoffMs: cutoffMs, cutoffBucket: cutoffBucket)
            DispatchQueue.main.async { completion(deleted) }
        }
    }

    // MARK: - Range clear (manual, by date interval)

    /// Delete rows whose timestamp/minutes fall in [fromMs, toMs) / [fromBucket,
    /// toBucket) across all five tables — including `process_alert`: the
    /// retention reminder counts alert rows as overdue, so the Settings
    /// cleanup must be able to clear them (same scope as `expiredRowCount`;
    /// unified 2026-10-09). Clearing the alert log also clears the
    /// (day, name_key, direction) dedup state, so a still-abnormal process
    /// may alert again the same day. Returns the total rows removed.
    func deleteRange(fromMs: Int64, toMs: Int64, fromBucket: Int, toBucket: Int,
                     completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(0) }; return }
            var total = 0
            for table in ["history", "interface_history", "process_alert"] {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "DELETE FROM \(table) WHERE ts >= ? AND ts < ?;"
                guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    Log.persistence.error("range delete \(table) prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                    continue
                }
                sqlite3_bind_int64(stmt, 1, fromMs)
                sqlite3_bind_int64(stmt, 2, toMs)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    total += Int(sqlite3_changes(self.db))
                }
            }
            for table in ["process_usage", "interface_minute"] {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                let sql = "DELETE FROM \(table) WHERE minute_bucket >= ? AND minute_bucket < ?;"
                guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    Log.persistence.error("range delete \(table) prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                    continue
                }
                sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
                sqlite3_bind_int64(stmt, 2, Int64(toBucket))
                if sqlite3_step(stmt) == SQLITE_DONE {
                    total += Int(sqlite3_changes(self.db))
                }
            }
            Log.persistence.info("range delete removed \(total) rows")
            DispatchQueue.main.async { completion(total) }
        }
    }

    // MARK: - Shared helpers (db queue only)

    private func removeExpiredSync(cutoffMs: Int64, cutoffBucket: Int) -> Int {
        var total = 0
        for table in ["history", "interface_history", "process_alert"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "DELETE FROM \(table) WHERE ts < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_DONE {
                total += Int(sqlite3_changes(db))
            }
        }
        for table in ["process_usage", "interface_minute"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "DELETE FROM \(table) WHERE minute_bucket < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, Int64(cutoffBucket))
            if sqlite3_step(stmt) == SQLITE_DONE {
                total += Int(sqlite3_changes(db))
            }
        }
        return total
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

    /// Append per-category minute-bucket rows. `interface_minute` stores
    /// cumulative *bytes* per local minute, written once per minute bucket to
    /// match the `process_usage` cadence used by the history window.
    func appendInterfaceMinute(_ rows: [(minuteBucket: Int, category: String, inBytes: Int, outBytes: Int)]) {
        queue.async { [weak self] in
            guard let self, !rows.isEmpty else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "INSERT INTO interface_minute (minute_bucket, category, in_bytes, out_bytes) VALUES (?, ?, ?, ?);"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("prepare interface-minute insert failed: \(String(cString: sqlite3_errmsg(self.db)))")
                return
            }
            for row in rows {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(row.minuteBucket))
                sqlite3_bind_text(stmt, 2, row.category, -1, SQLITE_TRANSIENT_BRIDGE)
                sqlite3_bind_int64(stmt, 3, Int64(row.inBytes))
                sqlite3_bind_int64(stmt, 4, Int64(row.outBytes))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    Log.persistence.error("interface-minute insert step failed: \(String(cString: sqlite3_errmsg(self.db)))")
                }
            }
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

    // MARK: - Process traffic alerts

    /// Insert one fired alert. Returns `inserted == false` when this process
    /// already alerted in this direction today (unique index hit) — the
    /// storage layer is the daily dedup. Main-queue callback.
    func appendProcessAlert(_ row: ProcessAlertRow, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(false) }; return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                INSERT OR IGNORE INTO process_alert
                    (day, name, name_key, direction, today_bytes, baseline_bytes, multiplier, ts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("prepare process_alert insert failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion(false) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(row.day))
            sqlite3_bind_text(stmt, 2, row.name, -1, SQLITE_TRANSIENT_BRIDGE)
            sqlite3_bind_text(stmt, 3, row.nameKey, -1, SQLITE_TRANSIENT_BRIDGE)
            sqlite3_bind_text(stmt, 4, row.direction, -1, SQLITE_TRANSIENT_BRIDGE)
            sqlite3_bind_int64(stmt, 5, Int64(row.todayBytes))
            sqlite3_bind_int64(stmt, 6, Int64(row.baselineBytes))
            sqlite3_bind_double(stmt, 7, row.multiplier)
            sqlite3_bind_int64(stmt, 8, row.ts)
            let inserted = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(self.db) > 0
            DispatchQueue.main.async { completion(inserted) }
        }
    }

    /// Whether today's dedup row already exists for `(day, nameKey, direction)`.
    /// Delivered on main. The process-alert monitor consults this *before*
    /// delivering so the banner itself fires at most once per day — the
    /// unique index alone only keeps the table clean, it does not stop a
    /// second `add`.
    func hasProcessAlert(day: Int, nameKey: String, direction: String,
                         completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, let db = self.db else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT 1 FROM process_alert WHERE day = ? AND name_key = ? AND direction = ? LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("prepare process_alert lookup failed: \(String(cString: sqlite3_errmsg(db)))")
                DispatchQueue.main.async { completion(false) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(day))
            sqlite3_bind_text(stmt, 2, nameKey, -1, SQLITE_TRANSIENT_BRIDGE)
            sqlite3_bind_text(stmt, 3, direction, -1, SQLITE_TRANSIENT_BRIDGE)
            let exists = sqlite3_step(stmt) == SQLITE_ROW
            DispatchQueue.main.async { completion(exists) }
        }
    }

    // MARK: - CSV export (history window)

    /// Convert a local minute ordinal (stored in `process_usage` /
    /// `interface_minute`) back to a Date for readable CSV timestamps.
    static func date(fromLocalMinuteBucket bucket: Int) -> Date {
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        return Date(timeIntervalSince1970: TimeInterval(bucket) * 60 - tz)
    }
}
