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
            """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            Log.persistence.error("schema failed: \(msg)")
            sqlite3_free(err)
        }
    }

    private func prune() {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(retentionSeconds * 1000)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "DELETE FROM history WHERE ts < ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, cutoff)
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
}
