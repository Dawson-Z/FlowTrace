//
//  InterfaceTopModel.swift
//  iTrafficPlus — Feature/Interface
//
//  Data model for "top process per interface type". Each interface type
//  (Wi-Fi / Wired including USB / AWDL) exposes the processes that are
//  moving the most bytes *over that type*, plus the per-type totals.
//
//  This is separate from `InterfaceSnapshot` (the per-category aggregate
//  bars) because it is *process-level*: it comes from `-P -t <type>`
//  nettop runs, not the socket-mode run.
//

import Foundation

/// One process's bytes on a given interface type.
struct InterfaceTopProcess: Equatable, Identifiable {
    let pid: Int
    let name: String
    let inBytesPerSec: Int
    let outBytesPerSec: Int

    var id: Int { pid }
    var totalBytesPerSec: Int { inBytesPerSec + outBytesPerSec }
}

/// The set of interface types we can get process-level top lists for.
/// 'Wired' includes USB devices (en11 etc.) because nettop's `-t` has no
/// separate 'usb' type — the user accepted USB collapsing into Wired.
enum InterfaceTopType: String, CaseIterable, Identifiable {
    case wifi  = "Wi-Fi"
    case wired = "Wired"
    case awdl  = "AWDL"

    var id: String { rawValue }

    /// The `-t` CLI argument for this type (nettop accepts these directly).
    var nettopArgument: String {
        switch self {
        case .wifi:  return "wifi"
        case .wired: return "wired"
        case .awdl:  return "awdl"
        }
    }

    var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .wifi:  return (0.33, 0.58, 0.95)
        case .wired: return (0.30, 0.75, 0.39)
        case .awdl:  return (0.98, 0.44, 0.22)
        }
    }
}

/// One interface type's top processes, plus that type's totals.
struct InterfaceTopSnapshot: Equatable {
    let type: InterfaceTopType
    let topProcesses: [InterfaceTopProcess]
    let totalInBytesPerSec: Int
    let totalOutBytesPerSec: Int
}
