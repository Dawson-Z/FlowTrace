//
//  AppLogger.swift
//  iTrafficPlus — Feature/Logging
//
//  Categorised os.Logger instances + a tee'd file sink.
//
//  Why both:
//  - os.Logger is the right place for categorised, level-tagged, logd-friendly
//    output. The deployment target is 11.0, so this is the modern path.
//  - macOS 11+ applies a privacy filter to os.log writes from **ad-hoc signed**
//    apps (and from CLI tools invoked outside Terminal). iTrafficPlus is
//    ad-hoc-signed and lives in /Applications-ish paths, so its os.log lines
//    are visible to Console.app's "Now" pane while you click the menu bar but
//    **do not** persist to the log store, and `log show` cannot read them back.
//    This is Apple behaviour, not a bug, and it is exactly the situation
//    researchers hit when iterating before paying for a Developer ID.
//  - The fallback sink writes the same line to a plain file the user owns
//    (`~/Library/Logs/iTrafficPlus.log`), which is unaffected by logd's
//    privacy filter and can be `tail -f`'d. File logging is enabled by
//    `ITRAFFICPLUS_FILE_LOG=1` in the process environment, or by default in
//    Debug builds. In a Developer ID-signed build, leave it off.
//
//  A single subsystem + three categories map to source files, so a log line
//  can be traced to one file and one subsystem.
//
//  Migration from `print`: `print("[NettopRunner] failed to spawn: \(error)")`
//  becomes `AppLogger.runner.error("failed to spawn: \(error.localizedDescription)")`.
//

import Foundation
import os.log

private let subsystem = "local.iTrafficPlus"

enum AppLogger {
    /// AppDelegate.swift — popover lifecycle, child window plumbing.
    static let appDelegate = Logger(subsystem: subsystem, category: "appDelegate")
    /// Network.swift — parser, deep-sleep machinery, per-frame totals.
    static let network = Logger(subsystem: subsystem, category: "network")
    /// Service/NettopRunner.swift — nettop subprocess, debounce, restart.
    static let nettopRunner = Logger(subsystem: subsystem, category: "nettopRunner")
}

/// File sink used when os.log is unavailable to the user. Writes one line per
/// entry, prefixed with ISO-8601 timestamp, level, and category.
enum LogFileSink {
    private static let queue = DispatchQueue(label: "local.iTrafficPlus.LogFileSink")
    private static let enabled: Bool = {
        if let v = ProcessInfo.processInfo.environment["ITRAFFICPLUS_FILE_LOG"], v == "1" {
            return true
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("iTrafficPlus.log")
    }()

    static var logFileURL: URL? { enabled ? url : nil }

    static func append(level: String, category: String, message: String) {
        guard enabled else { return }
        queue.async {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
