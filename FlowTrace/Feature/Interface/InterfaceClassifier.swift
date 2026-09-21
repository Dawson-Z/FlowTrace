//
//  InterfaceClassifier.swift
//  FlowTrace — Feature/Interface
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
//  We parse the *entire* hardware-ports table once, keyed by device, and
//  classify by the "Hardware Port" string first:
//    - "Wi-Fi"                -> wifi
//    - "USB" / "Ethernet" /
//      "Thunderbolt"          -> wired  (USB tethering like iPhone's en11
//                                         is folded into Wired by design)
//  Then fall back to a name heuristic for devices that never show up in
//  the table (virtual/dynamic):
//    - `awdl0` / `llw0`   -> localDirect
//    - numeric `en*`      -> wired  (dynamic USB/Thunderbolt NICs like
//                                    en13, en2-en4 on this machine)
//    - `bridge*` or unknown -> other
//
//  This stays a *pure* classifier over (name, portByDevice) so the
//  interesting logic is unit-testable without process state.
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
    /// and returns a map of device name -> Hardware Port string. Best
    /// effort: a failure returns an empty dict, which just means the
    /// classifier relies on the name heuristics alone.
    static func discoverPortByDevice() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        var portByDevice: [String: String] = [:]
        var currentPort = ""
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                currentPort = trimmed.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:") {
                let device = trimmed.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    portByDevice[device] = currentPort
                }
            }
        }
        return portByDevice
    }

    let portByDevice: [String: String]

    init(portByDevice: [String: String] = InterfaceClassifier.discoverPortByDevice()) {
        self.portByDevice = portByDevice
    }

    func classify(_ interfaceName: String) -> InterfaceCategory {
        let name = interfaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .other }

        // AWDL + Low-Power-WLAN are peer-to-peer / device-to-device
        // (AirDrop, AirPlay, Continuity) — label them LocalDirect.
        let lower = name.lowercased()
        if lower == "awdl0" || lower == "llw0" { return .localDirect }

        // Known hardware ports win over the `en*` heuristic, because on a
        // Mac the Wi-Fi NIC is itself an `en*` device (here en1).
        if let port = portByDevice[name] {
            let p = port.lowercased()
            if p == "wifi" { return .wifi }
            // USB / Ethernet / Thunderbolt all count as wired. (There is no
            // separate 'usb' bucket — the user chose to fold USB tethering
            // into Wired.)
            if p.contains("usb") || p.contains("ethernet") || p.contains("thunderbolt") {
                return .wired
            }
        }

        // Everything that looks like an ethernet-family device (en*) —
        // including dynamic ones like en13 — is wired-like. (Reached only
        // when the device was not in the hardware-ports table.)
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
