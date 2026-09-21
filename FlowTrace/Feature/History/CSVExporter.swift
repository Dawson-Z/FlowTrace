//
//  CSVExporter.swift
//  FlowTrace — Feature/History
//
//  Turns the history window's rows into CSV and saves them via an
//  `NSSavePanel`. Three shapes: per-process (process-stats tab),
//  per-interface (network-heatmap tab) and per-alert (alert-log tab). Bytes
//  are exported as plain numbers (B), so spreadsheets can sum them; the
//  header names the unit.
//

import AppKit

enum CSVExporter {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func processCSV(_ rows: [(time: Date, name: String, inBytes: Int, outBytes: Int)]) -> String {
        var csv = "Time,Process,Download (bytes),Upload (bytes)\n"
        for r in rows {
            csv += "\(timeFormatter.string(from: r.time)),\(escape(r.name)),\(r.inBytes),\(r.outBytes)\n"
        }
        return csv
    }

    static func interfaceCSV(_ rows: [(time: Date, category: String, inBytes: Int, outBytes: Int)]) -> String {
        var csv = "Time,Interface,Download (bytes),Upload (bytes)\n"
        for r in rows {
            csv += "\(timeFormatter.string(from: r.time)),\(escape(r.category)),\(r.inBytes),\(r.outBytes)\n"
        }
        return csv
    }

    /// One row per fired alert (alert-log tab). `Direction` uses the stored
    /// vocabulary ("in" / "out") rather than the ↓ / ↑ glyphs the table draws,
    /// and `Factor` is left empty when the 7-day median was zero — the ratio
    /// is undefined there (the record encodes it as 0 rather than a real
    /// value, so writing 0 would read as "no increase").
    static func alertCSV(_ records: [AlertRecord]) -> String {
        var csv = "Time,Process,Direction,Today (bytes),Median 7d (bytes),Factor\n"
        for r in records {
            let factor = r.baselineBytes > 0 ? String(format: "%.2f", r.multiplier) : ""
            csv += "\(timeFormatter.string(from: r.date)),\(escape(r.name)),\(r.isIn ? "in" : "out"),\(r.todayBytes),\(r.baselineBytes),\(factor)\n"
        }
        return csv
    }

    /// Present a save panel and write `csv` to the chosen file.
    static func save(csv: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedFileTypes = ["csv"]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                Log.persistence.info("exported CSV to \(url.path)")
            } catch {
                Log.persistence.error("CSV export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Quote a field if it contains a comma / quote / newline.
    private static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
