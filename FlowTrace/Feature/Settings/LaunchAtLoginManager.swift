//
//  LaunchAtLoginManager.swift
//  FlowTrace — Feature/Settings
//
//  Manages the "Launch at login" toggle. Uses SMAppService on macOS 13+
//  (the only non-deprecated, app-store-compliant way to register a regular
//  .app as a login item since macOS 13). On macOS 11–12 — the lower bound
//  of FlowTrace's deployment target — there is no supported equivalent
//  for the *main app*: the old SMLoginItemSetEnabled only registers a
//  helper bundle, and the pre-13 LSSharedFileList path is deprecated and
//  does not survive notarisation. So on 11–12 we report `.unsupported`
//  rather than silently doing nothing the user cannot rely on.
//
//  Why #available and not raising the deployment target: AGENTS.md's rule
//  for this fork is "guard new API with #available rather than raising the
//  target", because the upstream supports macOS 10.15/11 users.
//

import SwiftUI
import ServiceManagement

enum LaunchAtLoginManager {

    enum Status: Equatable {
        case enabled
        case disabled
        case unsupported
        case failed(String)
    }

    // MARK: - Read (current OS state)

    static func currentStatus() -> Status {
        if #available(macOS 13.0, *) {
            let canRegister = SMAppService.mainApp.status
            switch canRegister {
            case .enabled:  return .enabled
            case .requiresApproval:
                // Registered but waiting for the user to approve in
                // System Settings. Treat as enabled so the UI shows the
                // toggle in the 'on' position.
                return .enabled
            default:        return .disabled
            }
        } else {
            return .unsupported
        }
    }

    // MARK: - Write

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Status {
        guard #available(macOS 13.0, *) else {
            return .unsupported
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        return currentStatus()
    }

    // MARK: - Rename migration

    /// SMAppService registrations are bound to the bundle id. The app was
    /// renamed from iTrafficPlus (`local.iTrafficPlus`) to FlowTrace
    /// (`local.FlowTrace`), so a migrated `launchAtLogin = true` points at a
    /// login item that no longer matches this app. If the setting is on but
    /// the OS registration for the *current* bundle id is missing, register
    /// once at launch so the toggle keeps working across the rename.
    static func ensureRegisteredAfterRename() {
        guard #available(macOS 13.0, *) else { return }
        guard SettingsStore.shared.launchAtLogin else { return }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            break // already registered under the new identity
        case .notRegistered, .notFound:
            do { try SMAppService.mainApp.register() }
            catch { Log.settings.error("[migration] login-item re-register failed: \(error.localizedDescription)") }
        @unknown default:
            break
        }
    }
}
