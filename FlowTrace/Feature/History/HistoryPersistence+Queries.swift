//
//  HistoryPersistence+Queries.swift
//  FlowTrace — Feature/History
//
//  The read-only half of HistoryPersistence: the synchronous launch seed,
//  the async aggregates behind the popover / history window / alerts, and
//  the raw row reads the CSV export walks.
//

import Foundation
import SQLite3

extension HistoryPersistence {

    // MARK: - Retention cleanup (scheduled checkpoint)

    /// Number of rows currently older than the retention cutoff, summed
    /// across all four tables. `cutoffMs` is the epoch-ms threshold for the
    /// `ts` tables; `cutoffBucket` the local-minute threshold for the
    /// `minute_bucket` tables. Used by the reminder notification.
    func expiredRowCount(cutoffMs: Int64, cutoffBucket: Int,
                         completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(0) }; return }
            let count = self.expiredCountSync(cutoffMs: cutoffMs, cutoffBucket: cutoffBucket)
            DispatchQueue.main.async { completion(count) }
        }
    }

    // MARK: - Range clear (manual, by date interval)

    /// Count rows in [fromMs, toMs) / [fromBucket, toBucket) for the
    /// confirmation dialog before a manual range delete. Same five-table
    /// scope as `deleteRange` — including `process_alert` (unified with the
    /// retention reminder's `expiredRowCount` scope, 2026-10-09).
    func countRange(fromMs: Int64, toMs: Int64, fromBucket: Int, toBucket: Int,
                    completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(0) }; return }
            var total = 0
            for table in ["history", "interface_history", "process_alert"] {
                let c = self.scalarInt("SELECT COUNT(*) FROM \(table) WHERE ts >= ? AND ts < ?;",
                                       a: Int64(fromMs), b: Int64(toMs))
                total += c
            }
            for table in ["process_usage", "interface_minute"] {
                let c = self.scalarInt("SELECT COUNT(*) FROM \(table) WHERE minute_bucket >= ? AND minute_bucket < ?;",
                                       a: Int64(fromBucket), b: Int64(toBucket))
                total += c
            }
            DispatchQueue.main.async { completion(total) }
        }
    }

    // MARK: - Shared helpers (db queue only)

    private func scalarInt(_ sql: String, a: Int64, b: Int64) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int64(stmt, 1, a)
        sqlite3_bind_int64(stmt, 2, b)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func expiredCountSync(cutoffMs: Int64, cutoffBucket: Int) -> Int {
        var total = 0
        for table in ["history", "interface_history", "process_alert"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COUNT(*) FROM \(table) WHERE ts < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            if sqlite3_step(stmt) == SQLITE_ROW {
                total += Int(sqlite3_column_int64(stmt, 0))
            }
        }
        for table in ["process_usage", "interface_minute"] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COUNT(*) FROM \(table) WHERE minute_bucket < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, Int64(cutoffBucket))
            if sqlite3_step(stmt) == SQLITE_ROW {
                total += Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return total
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
        // Today's cumulative bytes. `history` stores bytes/sec at the fixed
        // 1 s sample, so SUM(in_bps) equals today's in-bytes (same for out).
        let todayInBytes  = intValue(sql: "SELECT SUM(in_bps) FROM history WHERE ts >= ?;", tsMs: dayStartMs)
        let todayOutBytes = intValue(sql: "SELECT SUM(out_bps) FROM history WHERE ts >= ?;", tsMs: dayStartMs)

        return HistorySummary(
            todayPeakIn: peakIn, todayPeakOut: peakOut,
            avgLast24hIn: avgIn, avgLast24hOut: avgOut,
            todayInBytes: todayInBytes, todayOutBytes: todayOutBytes
        )
    }

    // MARK: - Heatmap aggregation

    /// The per-category heatmap reads the *minute* table (not the per-frame
    /// `interface_history`), so the history window stays on a minute-cadence
    /// source just like `process_usage`. `minute_bucket` is a local minute
    /// ordinal, so `/ 60` is the local hour bucket. The stored values are
    /// already bytes, so no interval factor is applied.
    func interfaceMinuteHeatmap(fromMs: Int64, toMs: Int64,
                                categories: [String],
                                completion: @escaping ([HeatmapCell]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !categories.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let tzMs = Int64(TimeZone.current.secondsFromGMT()) * 1000
            let fromBucket = Int64((fromMs + tzMs) / 60000)
            let toBucket = Int64((toMs + tzMs) / 60000)
            let placeholders = categories.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT minute_bucket / 60 AS bucket,
                       SUM(in_bytes), SUM(out_bytes)
                FROM interface_minute
                WHERE minute_bucket >= ? AND minute_bucket < ? AND category IN (\(placeholders))
                GROUP BY bucket
                ORDER BY bucket;
                """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("interface-minute heatmap prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([]) }
                return
            }
            var index: Int32 = 1
            sqlite3_bind_int64(stmt, index, fromBucket); index += 1
            sqlite3_bind_int64(stmt, index, toBucket); index += 1
            for category in categories {
                sqlite3_bind_text(stmt, index, category, -1, SQLITE_TRANSIENT_BRIDGE); index += 1
            }
            var cells: [HeatmapCell] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bucket = Int(sqlite3_column_int64(stmt, 0))
                cells.append(HeatmapCell(
                    day: bucket / 24,
                    hour: bucket % 24,
                    inBytes: Int(sqlite3_column_int64(stmt, 1)),
                    outBytes: Int(sqlite3_column_int64(stmt, 2))
                ))
            }
            DispatchQueue.main.async { completion(cells) }
        }
    }

    /// Cumulative bytes per `InterfaceCategory` over a ms range, for the
    /// popover's "today" interface summary. The table stores per-frame
    /// *rates* (bytes/sec); a row represents `interval` seconds of traffic,
    /// so cumulative bytes = SUM(rate) × interval. Today's sample is the
    /// fixed 1 s window, making this accurate for the current session.
    func interfaceUsageBytes(fromMs: Int64, toMs: Int64, interval: Int,
                             completion: @escaping ([String: (in: Int, out: Int)]) -> Void) {
        queue.async { [weak self] in
            guard let self, interval > 0 else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            var rows: [String: (in: Int, out: Int)] = [:]
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT category, SUM(in_bps), SUM(out_bps)
                FROM interface_history
                WHERE ts >= ? AND ts < ?
                GROUP BY category;
                """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("interface usage query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([:]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, fromMs)
            sqlite3_bind_int64(stmt, 2, toMs)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cat = sqlite3_column_text(stmt, 0) {
                    let inSum = Int(sqlite3_column_int64(stmt, 1)) * interval
                    let outSum = Int(sqlite3_column_int64(stmt, 2)) * interval
                    rows[String(cString: cat)] = (in: inSum, out: outSum)
                }
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    // MARK: - Process usage (per-app usage history)

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

    /// Real-time in/out totals over a timestamp range, from the `history`
    /// table. `history` is written every frame, so the figures track live
    /// traffic (used by the menu-bar today/this-month totals). Bytes are
    /// SUM(rate) at the fixed 1 s sample, matching the popover's today total.
    func historyUsageBytes(fromMs: Int64, toMs: Int64,
                           completion: @escaping ((in: Int, out: Int)) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion((0, 0)) }
                return
            }
            var inB = 0, outB = 0
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT SUM(in_bps), SUM(out_bps) FROM history WHERE ts >= ? AND ts < ?;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("historyUsageBytes query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion((0, 0)) }
                return
            }
            sqlite3_bind_int64(stmt, 1, fromMs)
            sqlite3_bind_int64(stmt, 2, toMs)
            if sqlite3_step(stmt) == SQLITE_ROW {
                inB = Int(sqlite3_column_int64(stmt, 0))
                outB = Int(sqlite3_column_int64(stmt, 1))
            }
            DispatchQueue.main.async { completion((in: inB, out: outB)) }
        }
    }

    // MARK: - Process traffic alerts

    /// Alert records for the history window's alert tab, newest first,
    /// restricted to `fromMs` (epoch ms lower bound; 0 = no filter).
    func alertRecords(fromMs: Int64 = 0, limit: Int = 500,
                      completion: @escaping ([AlertRecord]) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion([]) }; return }
            var records: [AlertRecord] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT ts, name, direction, today_bytes, baseline_bytes, multiplier
                FROM process_alert WHERE ts >= ? ORDER BY ts DESC LIMIT ?;
                """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("alert records query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, fromMs)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts = sqlite3_column_int64(stmt, 0)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let direction = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "in"
                records.append(AlertRecord(
                    date: Date(timeIntervalSince1970: TimeInterval(ts) / 1000),
                    name: name,
                    isIn: direction == "in",
                    todayBytes: Int(sqlite3_column_int64(stmt, 3)),
                    baselineBytes: Int(sqlite3_column_int64(stmt, 4)),
                    multiplier: sqlite3_column_double(stmt, 5)
                ))
            }
            DispatchQueue.main.async { completion(records) }
        }
    }

    /// Per-process per-day totals over the local-minute bucket range
    /// [fromBucket, toBucket), keyed `nameKey -> day ordinal -> (in, out)`.
    /// Used to build the 7-day daily-median baseline for traffic alerts.
    func dailyProcessTotals(fromBucket: Int, toBucket: Int,
                            completion: @escaping ([String: [Int: (in: Int, out: Int)]]) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion([:]) }; return }
            var totals: [String: [Int: (in: Int, out: Int)]] = [:]
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
                SELECT name_key, minute_bucket / 1440 AS day, SUM(in_bytes), SUM(out_bytes)
                FROM process_usage WHERE minute_bucket >= ? AND minute_bucket < ?
                GROUP BY name_key, day;
                """
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("daily totals query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([:]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
            sqlite3_bind_int64(stmt, 2, Int64(toBucket))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let day = Int(sqlite3_column_int64(stmt, 1))
                let inB = Int(sqlite3_column_int64(stmt, 2))
                let outB = Int(sqlite3_column_int64(stmt, 3))
                totals[key, default: [:]][day] = (in: inB, out: outB)
            }
            DispatchQueue.main.async { completion(totals) }
        }
    }

    /// Per-process cumulative bytes since `fromBucket` (local minute), used
    /// to seed today's accumulator after a restart.
    func todayProcessTotals(fromBucket: Int,
                            completion: @escaping ([String: (in: Int, out: Int)]) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion([:]) }; return }
            var totals: [String: (in: Int, out: Int)] = [:]
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT name_key, SUM(in_bytes), SUM(out_bytes) FROM process_usage WHERE minute_bucket >= ? GROUP BY name_key;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("today totals query failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([:]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                totals[key] = (in: Int(sqlite3_column_int64(stmt, 1)),
                               out: Int(sqlite3_column_int64(stmt, 2)))
            }
            DispatchQueue.main.async { completion(totals) }
        }
    }

    // MARK: - CSV export (history window)

    /// Raw per-interface minute rows for CSV export (heatmap tab): the
    /// minute's time, interface category and cumulative bytes.
    func exportInterfaceMinute(fromBucket: Int, toBucket: Int,
                               completion: @escaping ([(time: Date, category: String, inBytes: Int, outBytes: Int)]) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion([]) }; return }
            var rows: [(time: Date, category: String, inBytes: Int, outBytes: Int)] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT minute_bucket, category, in_bytes, out_bytes FROM interface_minute WHERE minute_bucket >= ? AND minute_bucket < ? ORDER BY minute_bucket, category;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("export interface prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
            sqlite3_bind_int64(stmt, 2, Int64(toBucket))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bucket = Int(sqlite3_column_int64(stmt, 0))
                let cat = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                rows.append((time: Self.date(fromLocalMinuteBucket: bucket),
                             category: cat,
                             inBytes: Int(sqlite3_column_int64(stmt, 2)),
                             outBytes: Int(sqlite3_column_int64(stmt, 3))))
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Raw per-process minute rows for CSV export (process-stats tab).
    func exportProcessUsage(fromBucket: Int, toBucket: Int,
                            completion: @escaping ([(time: Date, name: String, inBytes: Int, outBytes: Int)]) -> Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion([]) }; return }
            var rows: [(time: Date, name: String, inBytes: Int, outBytes: Int)] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT minute_bucket, name, in_bytes, out_bytes FROM process_usage WHERE minute_bucket >= ? AND minute_bucket < ? ORDER BY minute_bucket, name;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.persistence.error("export process prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
                DispatchQueue.main.async { completion([]) }
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(fromBucket))
            sqlite3_bind_int64(stmt, 2, Int64(toBucket))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bucket = Int(sqlite3_column_int64(stmt, 0))
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                rows.append((time: Self.date(fromLocalMinuteBucket: bucket),
                             name: name,
                             inBytes: Int(sqlite3_column_int64(stmt, 2)),
                             outBytes: Int(sqlite3_column_int64(stmt, 3))))
            }
            DispatchQueue.main.async { completion(rows) }
        }
    }
}
