//
//  Utils.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/23.
//

import Foundation
import Cocoa
import Darwin

func formatBytes(bytes: Int) -> String {
    if bytes <= 0 { return "0 KB/s" }
    let kbyte = Double(bytes) / 1024
    if kbyte < 1024 {
        return String(format:"%.1f KB/s", kbyte)
    }
    let mbyte = kbyte / 1024
    if mbyte < 1024 {
        return String(format:"%.1f MB/s", mbyte)
    }
    let gbyte = mbyte / 1024
    return String(format:"%.1f GB/s", gbyte)
}

/// Compact unit format for list rows: "55K", "9.1M", "1.2G", "—" for 0.
/// Input is bytes **per second**, same unit as the menu bar; the `/s` suffix is
/// dropped only to keep the row narrow.
func formatBytesCompact(bytes: Int) -> String {
    if bytes <= 0 { return "—" }
    let kb = Double(bytes) / 1024
    if kb < 0.05 { return "—" }
    if kb < 1000 {
        return kb < 10 ? String(format: "%.1fK", kb) : String(format: "%.0fK", kb)
    }
    let mb = kb / 1024
    if mb < 1000 {
        return mb < 10 ? String(format: "%.1fM", mb) : String(format: "%.0fM", mb)
    }
    let gb = mb / 1024
    return gb < 10 ? String(format: "%.1fG", gb) : String(format: "%.0fG", gb)
}

struct AppInfo {
    var icon: NSImage
    var name: String?
    var updateTime: Int
}

var APP_INFO_CACHE = [Int: AppInfo]()
var CACHE_TTL = 3600

/// Cache for *aggregated history* rows, keyed by process NAME — never by pid.
/// `getAppInfo(pid: 0, …)` would funnel every row through the pid-0 cache
/// slot and display the first-seen name for all rows ("multiple identical
/// apps" bug).
var USAGE_INFO_CACHE = [String: AppInfo]()

/// Resolve a best-effort icon for an aggregated history row. The display
/// name stays the raw process name (the stable grouping key): bundling
/// helpers under their host app's label would re-create visually duplicate
/// rows. Only the icon is borrowed from a matching running app, if any.
func getAggregatedAppInfo(name: String) -> AppInfo {
    let key = name.lowercased()
    let timestamp = Int(NSDate().timeIntervalSince1970)
    if let cached = USAGE_INFO_CACHE[key], (timestamp - cached.updateTime) < CACHE_TTL {
        return cached
    }

    var resolved: NSRunningApplication?
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
    // 1. Exact executable-name match.
    for app in apps {
        if let exec = app.executableURL?.deletingPathExtension().path.lowercased(), exec == key {
            resolved = app
            break
        }
    }
    // 2. Helper processes: localizedName as a prefix of the process name
    //    ("Trae CN" ↦ "trae cn helper").
    if resolved == nil {
        for app in apps {
            if let label = app.localizedName?.lowercased(), !label.isEmpty,
               key.hasPrefix(label) {
                resolved = app
                break
            }
        }
    }

    let icon = resolved?.icon ?? NSImage(named: "blank") ?? NSImage()
    let info = AppInfo(icon: icon, name: name, updateTime: timestamp)
    USAGE_INFO_CACHE[key] = info
    return info
}

/// Resolve icon + display name for a PID:
/// 1. Try `NSRunningApplication(pid)` directly (GUI apps).
/// 2. If not found, walk the parent process tree up to 6 levels until
///    we hit something `NSRunningApplication` recognises — typically
///    the terminal / IDE that launched the CLI tool — and reuse its
///    icon. The display name becomes `ParentName-originalName` so the
///    raw binary name (`2.1.114`, `node`, …) is still visible.
/// Cached per-PID for `CACHE_TTL` seconds.
func getAppInfo(pid: Int, name: String) -> AppInfo? {
    let timestamp = Int(NSDate().timeIntervalSince1970)
    if let cached = APP_INFO_CACHE[pid], (timestamp - cached.updateTime) < CACHE_TTL {
        return cached
    }

    var resolvedApp = NSRunningApplication(processIdentifier: pid_t(pid))
    var walkedToAncestor = false

    if resolvedApp == nil {
        var current = pid
        for _ in 0..<6 {
            guard let pp = parentPid(of: current), pp > 1 else { break }
            current = pp
            if let app = NSRunningApplication(processIdentifier: pid_t(pp)) {
                resolvedApp = app
                walkedToAncestor = true
                break
            }
        }
    }

    // Keep the original NSImage (multi-rep, Retina-aware). Pre-
    // rasterising to a fixed pixel size via lockFocus produced soft
    // icons on 2x displays. SwiftUI's Image will downscale crisply
    // when given an unrasterised NSImage + `.interpolation(.high)`.
    let icon = resolvedApp?.icon ?? NSImage(named: "blank") ?? NSImage()

    let displayName: String
    if let label = resolvedApp?.localizedName, !label.isEmpty {
        if walkedToAncestor {
            // Avoid "Slack-Slack Helper" — drop the parent prefix if the
            // child name already starts with it (case-insensitive).
            let lname = name.lowercased()
            let llabel = label.lowercased()
            if lname.hasPrefix(llabel) || lname.contains(llabel) {
                displayName = name
            } else {
                displayName = "\(label) · \(name)"
            }
        } else {
            displayName = label
        }
    } else {
        displayName = name
    }

    let info = AppInfo(icon: icon, name: displayName, updateTime: timestamp)
    APP_INFO_CACHE[pid] = info
    return info
}

/// Look up a process's parent PID via sysctl.
private func parentPid(of pid: Int) -> Int? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
    let result = mib.withUnsafeMutableBufferPointer { ptr -> Int32 in
        sysctl(ptr.baseAddress, UInt32(ptr.count), &info, &size, nil, 0)
    }
    guard result == 0, size > 0 else { return nil }
    return Int(info.kp_eproc.e_ppid)
}

// Note: previous versions did manual `lockFocus`/`draw` rasterisation
// to a fixed pixel size — that rendered at 1x on Retina displays.
// All scaling is now done by SwiftUI via `.resizable().interpolation(.high)`.
