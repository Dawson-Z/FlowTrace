//
//  InterfaceClassifier.swift
//  iTrafficPlus — Feature/Interface
//
//  Maps a network-interface name (as reported by nettop's socket-mode
//  `interface` column, e.g. `en1`, `bridge100`, `awdl0`, `en13`) to a
//  coarse semantic label the user actually cares about: Wi-Fi, Wired,
//  LocalDirect (AWDL / peer-to-peer), or Other.
//
//  Why not hard-code interface names
//  --------------------------------
//  On the author's test machine the *live* sockets were on `en11`
//  (iPhone USB), `bridge100` (hotspot bridge), `awdl0`, `en13`, `en1`
//  (Wi-Fi) — but `networksetup -listallhardwareports` only listed
//  en0/en5/en6/en10/en1/en11/en2/en3/en4. `en13`, `bridge100`, `awdl0`
//  and `llw0` are *virtual/dynamic* interfaces that never appear in the
//  hardware-ports list. So a fixed table cannot work.
//
//  Strategy
//  --------
//  1. Every interface name is classified as "wired-like" if it is a
//     numeric `en*` (ethernet-family device) — even if dynamically
//     created (en13). This keeps the common Mac case correct: on this
//     machine the Wi-Fi is `en1`, so we must **not** blanket-treat all
//     `en*` as wired.
//  2. The Wi-Fi device name(s) are discovered at runtime from
//     `networksetup -listallhardwareports` (Hardware Port == "Wi-Fi").
//     Those names override the `en*` heuristic and are classified Wi-Fi.
//  3. Known Apple Wireless Direct Link names are LocalDirect.
//  4. Everything else is Other.
//
//  This is intentionally a *pure* classifier over a name + a set of
//  known Wi-Fi device names, so the interesting logic is unit-testable
//  without touching process/network state.
//

import Foundation

/// The coarse semantic bucket an interface belongs to.
enum InterfaceCategory: String, CaseIterable, Identifiable {
    case wifi        = "Wi-Fi"
    case wired       = "Wired"
    case localDirect = "Local Direct"
    case other       = "Other"

    var id: String { rawValue }
}

struct InterfaceClassifier {

    /// Run once at startup; parses `networksetup -listallhardwareports`
    /// and returns the device names whose Hardware Port is "Wi-Fi"
    /// (typically just `en1`). Deliberately best-effort: a failure here
    /// just means no `en*` gets special-cased as Wi-Fi.
    static func discoverWiFiDeviceNames() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        var wifiNames: Set<String> = []
        var currentPort = ""
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentPort = trimmed.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:") {
                let device = trimmed.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if currentPort == "Wi-Fi" {
                    wifiNames.insert(device)
                }
            }
        }
        return wifiNames
    }

    let wifiDeviceNames: Set<String>

    init(wifiDeviceNames: Set<String> = InterfaceClassifier.discoverWiFiDeviceNames()) {
        self.wifiDeviceNames = wifiDeviceNames
    }

    func classify(_ interfaceName: String) -> InterfaceCategory {
        let name = interfaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .other }

        // AWDL + Low-Power-WLAN are peer-to-peer / device-to-device
        // (AirDrop, AirPlay, Continuity) — label them LocalDirect.
        let lower = name.lowercased()
        if lower == "awdl0" || lower == "llw0" { return .localDirect }

        // Explicit Wi-Fi device names override the generic `en*` rule.
        if wifiDeviceNames.contains(name) { return .wifi }

        // Everything that looks like an ethernet-family device (en*) —
        // including dynamic ones like en13 — is wired-like.
        if lower.hasPrefix("en") && lower.dropFirst().allSatisfy({ $0.isNumber }) {
            return .wired
        }

        // `bridge*` is a bridge (hotspot / tunnel aggregation). It carries
        // real external traffic but is not the physical NIC, so bucket it
        // as Other rather than claiming a specific wired/wifi identity.
        if lower.hasPrefix("bridge") { return .other }

        return .other
    }
}
