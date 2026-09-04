//
//  LogHelpers.swift
//  iTrafficPlus — Feature/Logging
//
//  Convenience wrappers that tee each log line into both os.Logger (for
//  Console.app "Now" pane) and LogFileSink (for `tail -f` verification).
//  This is the *only* recommended call site for log writes in this fork:
//  use `Log.appDelegate.info("...")`, not `AppLogger.appDelegate.info("...")`
//  directly, so every line ends up in both sinks.
//

import Foundation
import os

/// Wrapper around `AppLogger` that tees every line to the file sink. Use
/// this instead of `AppLogger` so private-file verification works.
enum Log {
    static let appDelegate = LogHelper(category: "appDelegate")
    static let network     = LogHelper(category: "network")
    static let nettopRunner = LogHelper(category: "nettopRunner")
    static let persistence = LogHelper(category: "persistence")
    static let settings = LogHelper(category: "settings")
}

struct LogHelper {
    let category: String

    private func logger() -> Logger {
        switch category {
        case "appDelegate":  return AppLogger.appDelegate
        case "network":      return AppLogger.network
        case "nettopRunner": return AppLogger.nettopRunner
        case "persistence":  return AppLogger.persistence
        case "settings":     return AppLogger.settings
        default:             return AppLogger.appDelegate
        }
    }

    func debug(_ message: String) {
        logger().debug("\(message, privacy: .public)")
        LogFileSink.append(level: "DEBUG", category: category, message: message)
    }

    func info(_ message: String) {
        logger().info("\(message, privacy: .public)")
        LogFileSink.append(level: "INFO",  category: category, message: message)
    }

    func error(_ message: String) {
        logger().error("\(message, privacy: .public)")
        LogFileSink.append(level: "ERROR", category: category, message: message)
    }
}
