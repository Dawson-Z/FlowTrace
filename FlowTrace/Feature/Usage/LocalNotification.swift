//
//  LocalNotification.swift
//  FlowTrace — Feature/Usage
//
//  The one place a local notification is actually handed to the system.
//
//  Why this exists instead of a bare `UNUserNotificationCenter.add(_:)`:
//  `add` reports **no error** when the app is not authorized. Measured on this
//  machine with the permission denied, it still completed with `error == nil`.
//  So "did the user actually get this?" cannot be answered from `add` alone,
//  and a caller that assumed success would mark the threshold/alert as sent and
//  never try again. Delivery therefore consults the authorization status first
//  and reports a real boolean.
//
//  The typealias is also the injection seam: `QuotaMonitor`,
//  `ProcessAlertMonitor` and `DataRetentionController` take a
//  `NotificationDelivery`, so a test can exercise both the delivered and the
//  refused path — the same pattern the monitors already use for
//  `SettingsStore` / `UsageAggregator` / `UserDefaults`.
//

import Foundation
import UserNotifications

/// Hands one request to the system and reports whether it was actually accepted
/// for delivery. Always calls back on the main queue.
typealias NotificationDelivery = (UNNotificationRequest, @escaping (Bool) -> Void) -> Void

enum LocalNotification {

    // MARK: - Click routing + actions (spec: .trellis/tasks/09-28-notification-interactions)

    /// `userInfo` key carrying the click-destination route. Body clicks are
    /// answered in the app delegate's `didReceive`; the value selects which
    /// window/tab to open.
    static let routeKey = "route"

    /// Route values. One per notification family:
    /// - process alert → history window, alert-log tab
    /// - quota threshold → settings window, quota pane
    /// - retention reminder → settings window, storage pane
    enum Route {
        static let historyAlerts = "history-alerts"
        static let settingsQuota = "settings-quota"
        static let settingsStorage = "settings-storage"
    }

    /// Category carrying the three quota-100% actions. Registered once at
    /// launch (and re-registered on locale change — action titles are frozen
    /// into the category at registration time).
    static let quota100CategoryID = "QUOTA_100"

    /// Action identifiers inside `quota100CategoryID`. The body click keeps
    /// the system's `UNNotificationDefaultActionIdentifier` and only
    /// navigates; dismiss changes no state (the spec's growth-based re-fire
    /// does not need to observe it).
    enum Quota100Action {
        static let acknowledge = "ACKNOWLEDGE"
        static let mute1Hour = "MUTE_1H"
        static let muteToday = "MUTE_TODAY"
    }

    /// (Re-)register the notification categories. Idempotent; called at
    /// launch and on locale change so the frozen action titles follow the
    /// chosen language.
    static func registerCategories() {
        let acknowledge = UNNotificationAction(identifier: Quota100Action.acknowledge,
                                               title: Loc.l("Acknowledge"), options: [])
        let mute1Hour = UNNotificationAction(identifier: Quota100Action.mute1Hour,
                                             title: Loc.l("Mute for 1 hour"), options: [])
        let muteToday = UNNotificationAction(identifier: Quota100Action.muteToday,
                                             title: Loc.l("Mute today"), options: [])
        let quota100 = UNNotificationCategory(identifier: quota100CategoryID,
                                              actions: [acknowledge, mute1Hour, muteToday],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([quota100])
    }

    /// Statuses under which the system will actually present a request.
    /// `notDetermined` and `denied` both mean the request would be dropped
    /// without any error surfacing to the caller.
    static func isDeliverable(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Production delivery: check authorization, then `add`.
    ///
    /// Completion is delivered on the main queue, so callers that update
    /// main-queue state (fired-key bookkeeping, the alert accumulator) do not
    /// have to hop themselves.
    static let deliver: NotificationDelivery = { request, completion in
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard isDeliverable(settings.authorizationStatus) else {
                Log.settings.error(
                    "notification refused: authorizationStatus=\(settings.authorizationStatus.rawValue)"
                    + " id=\(request.identifier) — grant it in System Settings → Notifications → FlowTrace"
                )
                DispatchQueue.main.async { completion(false) }
                return
            }
            center.add(request) { error in
                if let error {
                    Log.settings.error(
                        "notification delivery failed: \(error.localizedDescription) id=\(request.identifier)"
                    )
                }
                DispatchQueue.main.async { completion(error == nil) }
            }
        }
    }
}

/// Observable view of the app's notification authorization, for the Settings
/// panes. The Quota and Alerts panes show an inline warning while their
/// feature is enabled but the system would drop its notifications anyway —
/// the one state that used to be completely invisible (see the comment on
/// `deliver`: `add` reports no error in that case).
///
/// A pane owns this via `@StateObject` and calls `refresh()` on appear (a
/// pane is rebuilt on every tab switch, so appear is the reliable hook) and
/// `request()` when its feature toggle is switched on.
final class NotificationPermissionModel: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus?

    var isDenied: Bool { status == .denied }
    var isNotDetermined: Bool { status == .notDetermined }

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { self.status = settings.authorizationStatus }
        }
    }

    /// Ask the system for permission — the dialog only pops while the status
    /// is `notDetermined`; a `denied` answer is final and can only be changed
    /// in System Settings — then re-read so the pane's warning updates.
    func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }
}
