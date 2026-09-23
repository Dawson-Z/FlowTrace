//
//  LaunchAtLoginManager.swift
//  FlowTrace — Feature/Settings
//
//  Manages the "Launch at login" toggle, on two foundations because the
//  deployment floor is macOS 11 and the sanctioned API only exists from 13.
//
//  macOS 13+ uses `SMAppService.mainApp` — a per-app registration, queried and
//  granted through System Settings.
//
//  macOS 11–12 has no equivalent for the *main app*: `SMAppService` does not
//  exist there, `SMLoginItemSetEnabled` only registers a helper bundle living
//  in `Contents/Library/LoginItems/` (a second target, a second bundle, a
//  second signature), and `LSSharedFileList` is deprecated. So instead we drop
//  a launchd *user agent* into `~/Library/LaunchAgents` whose single job is
//  `/usr/bin/open -g` on this bundle. launchd scans that directory at every
//  login, which means writing the plist *is* the registration and deleting it
//  is the unregistration — no `launchctl` call to get wrong, and no
//  UserDefaults flag to drift: the file's presence is the state.
//
//  The cost of that choice is the plist records an absolute path, because
//  `open` needs something to open (`-b <bundle-id>` would instead depend on
//  LaunchServices having indexed this bundle). A build directory that moved or
//  was cleaned would leave launchd pointing at nothing, so `currentStatus()`
//  rewrites the plist whenever it finds one whose recorded path is not the
//  bundle we are running from. That keeps the repair inside this file rather
//  than adding a launch-time hook in `AppDelegate`.
//
//  Why #available and not raising the deployment target: AGENTS.md's rule for
//  this fork is "guard new API with #available rather than raising the target".
//

import Foundation
import ServiceManagement

enum LaunchAtLoginManager {

    enum Status: Equatable {
        case enabled
        case disabled
        case failed(String)
    }

    // MARK: - Read (current OS state)

    static func currentStatus() -> Status {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                // `requiresApproval` means registered but waiting for the user
                // to allow it in System Settings, so the toggle stays on.
                return .enabled
            default:
                return .disabled
            }
        } else {
            return LaunchAgent.isRegistered() ? .enabled : .disabled
        }
    }

    // MARK: - Write

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Status {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        } else {
            do {
                if enabled {
                    try LaunchAgent.write()
                } else {
                    try LaunchAgent.remove()
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return currentStatus()
    }

    // MARK: - macOS 11–12: the launchd user agent

    private enum LaunchAgent {

        /// Reverse-DNS, scoped to this fork's bundle id so it cannot collide
        /// with anything else in the user's `~/Library/LaunchAgents`.
        static let label = "local.FlowTrace.login"

        static var url: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent(label + ".plist")
        }

        /// Whether the agent is registered. As a side effect this rewrites an
        /// agent that points somewhere other than the running bundle, which is
        /// what keeps the toggle honest after the app is moved or the build
        /// directory is cleaned out.
        static func isRegistered() -> Bool {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            try? write()
            return true
        }

        static func write() throws {
            let plist: [String: Any] = [
                "Label": label,
                // `-g` keeps the app from stealing focus at login. `RunAtLoad`
                // without `KeepAlive` means launchd starts it once and does not
                // resurrect it if the user quits.
                "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }

        static func remove() throws {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    }
}
