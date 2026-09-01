//
//  AppLogger.swift
//  iTrafficPlus — Feature/Logging
//
//  Categorised os.Logger instances. One subsystem per app, one category per
//  concern, so the Console.app filter and `log show --predicate` lookups stay
//  readable. A single subsystem means a single privacy redaction rule for any
//  field the upstream marked as private (none today, but the rule is in place).
//
//  Migration from `print`: `print("[NettopRunner] failed to spawn: \(error)")`
//  becomes `AppLogger.runner.error("failed to spawn: \(error.localizedDescription)")`.
//  Categories map to source files so a log line can be traced to a single file.
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
