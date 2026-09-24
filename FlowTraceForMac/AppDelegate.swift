//
//  AppDelegate.swift
//  FlowTrace
//
//  Created by f.zou on 2021/5/19.
//

import Cocoa
import SwiftUI
import Combine
import UserNotifications

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    static var popover: NSPopover!
    var statusBarItem: NSStatusItem!
    var contentView: ContentView!
    var network: Network!
    // Plain reference. `@ObservedObject` on a non-View type has no subscription
    // semantics (no `body` to re-render), so the wrapper is a no-op. The view
    // tree gets the same `globalModel` through `withGlobalEnvironmentObjects()`
    // and observes it from there.
    var globalModel = SharedStore.globalModel
    
    static func quit() {
        NSApplication.shared.terminate(self)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Tee'd via Log.* so the line ends up in both os.log and
        // ~/Library/Logs/FlowTrace.log. See Feature/Logging/AppLogger.swift
        // for why both sinks are needed on macOS 11+ ad-hoc-signed builds.
        Log.appDelegate.info("applicationDidFinishLaunching entered; log file=\(LogFileSink.logFileURL?.path ?? "off")")

        // Menu-bar app (LSUIElement) is "active" almost all the time, and a
        // foreground app that does not implement willPresent only receives
        // notifications into Notification Center — no banner. Registering as
        // the delegate and returning [.banner,.list,.sound] makes quota and
        // abnormal-upload alerts visibly pop.
        UNUserNotificationCenter.current().delegate = self

        // Wire SQLite history persistence. Order matters: this MUST run
        // before any `historyStore.append` happens, otherwise the first
        // frames after launch are written to the in-memory store only and
        // never make it to disk. Network.startListenNetwork runs later
        // in this same method, so attach is safe here.
        //
        // Retention is read from the Settings store, not hard-coded — see
        // milestone 6. The store reads its own initial value from
        // UserDefaults before this line runs because SettingsStore.shared
        // is a static-let that is touched the first time the value is
        // needed (which is right here).
        let retention = TimeInterval(SettingsStore.shared.historyRetentionDays) * 24 * 3600
        if let persistence = HistoryPersistence(dbURL: HistoryPersistence.defaultDbURL(), retentionSeconds: retention) {
            SharedStore.attachHistoryPersistence(persistence)
            SharedStore.processAlertMonitor.bootstrap()
            // Same reason as the line above: `quotaMonitor` is a lazily
            // initialised `static let`, so its `init` — and with it the
            // subscriptions to `settings.$quotaEnabled` and the usage
            // aggregator — does not run until something touches the instance.
            // Nothing else in the launch path did, which left the quota feature
            // silently dead (no threshold could ever fire).
            SharedStore.quotaMonitor.bootstrap()
            Log.appDelegate.info("history persistence attached at \(persistence.dbURL.path); retention=\(Int(retention/86400))d")
        } else {
            Log.appDelegate.error("history persistence failed to open; falling back to in-memory only")
        }

        // See the method comment: the Settings toggles only request permission
        // at the moment they are flipped on, so an install whose toggle is
        // already on would otherwise never prompt.
        requestNotificationAuthorizationIfNeeded()

        self.contentView = ContentView()
        let statusBarView = AnyView(StatusBarView())
        self.network = Network()
        
        // Create the popover. Width 540 matches ContentView's
        // `.frame(width: 540)`; declaring the real width matters because
        // AppKit clamps the popover to the screen at `show` time using this
        // size — a stale smaller value let the window grow (to the right)
        // after positioning, pushing the right edge off-screen when the
        // status item sits at the far end of the menu bar. Height stays a
        // starting point: the sparkline grows it vertically.
        AppDelegate.popover = NSPopover()
        AppDelegate.popover.contentSize = NSSize(width: 540, height: 520)
        AppDelegate.popover.behavior = .transient
//        popover.contentViewController = NSHostingController(rootView: contentView.withGlobalEnvironmentObjects())
        
//        NSApp.activate(ignoringOtherApps: true)
        
        AppDelegate.popover.behavior = .transient
        AppDelegate.popover.animates = false
        // Create the status item
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))

        if let button = self.statusBarItem.button {
            button.action = #selector(togglePopover(_:))
            let hosting = NSHostingView(rootView: statusBarView)
            applyStatusBarFit(hosting, to: button)
            self.statusBarItem.length = statusBarLength

            // Extra segments (today / quota-period totals) change the ideal
            // width — re-measure whenever those settings flip.
            SettingsStore.shared.$showTodayInMenuBar
                .combineLatest(SettingsStore.shared.$showPeriodInMenuBar)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in
                    guard let self, let button = self.statusBarItem?.button else { return }
                    for sub in button.subviews {
                        self.applyStatusBarFit(sub, to: button)
                        self.statusBarItem?.length = self.statusBarLength
                    }
                }
                .store(in: &statusBarCancellables)
        }

        // Cached windows' titles are set once at creation (Loc.l reads the
        // then-current locale), so a runtime language change must re-apply
        // them or the stale language sticks until the window is recreated.
        // The settings toolbar's tab labels are AppKit strings for the same
        // reason, hence the extra call.
        LocalizationManager.shared.$locale
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.settingsWindow?.title = Loc.l("Settings")
                self?.historyWindow?.title = Loc.l("History")
            }
            .store(in: &windowTitleCancellables)

        self.network.startListenNetwork()

        // Daily retention checkpoint (auto-cleanup or reminder at the
        // configured time-of-day). No-op until persistence is attached above.
        DataRetentionController.shared.start()

        // TEMPORARY verification scaffold — remove.
        if let which = ProcessInfo.processInfo.environment["FLOWTRACE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if which == "history" { self?.showHistoryWindow() }
                else { self?.showSettingsWindow() }
            }
        }
    }

    // Menu-bar width mirrors StatusBarView's column layout:
    //   padding 6 + rate column 49 (if any rate) + 4 (the HStack's gap, only
    //   when both columns are present) + totals column 38 (if any)
    //   — never wider than the content, never clipping it.
    //
    // The 4 pt gap was missing, so the hosting view ran 4 pt short of its
    // ideal width and SwiftUI paid for it out of the last column: the totals
    // column ended up ~26 pt instead of 34, and "D 86M" — 27.98 pt — was
    // ellipsised to "D 86…".
    private var statusBarLength: CGFloat {
        var width: CGFloat = 6
        let anyRate = SettingsStore.shared.showDownloadInStatusBar
            || SettingsStore.shared.showUploadInStatusBar
        let anyTotal = SettingsStore.shared.showTodayInMenuBar
            || SettingsStore.shared.showPeriodInMenuBar
        if anyRate { width += 49 }
        if anyTotal {
            if anyRate { width += 4 }
            width += 38
        }
        return max(width, 40)
    }

    private var statusBarCancellables: Set<AnyCancellable> = []
    /// AppKit window titles are set imperatively and cannot re-read themselves
    /// after a language change, so they are re-applied from here.
    private var windowTitleCancellables: Set<AnyCancellable> = []

    private func applyStatusBarFit(_ view: NSView, to button: NSStatusBarButton) {
        let thickness = NSStatusBar.system.thickness
        let width = statusBarLength
        view.setFrameSize(NSSize(width: width, height: thickness))
        view.frame.origin = NSPoint(x: 0, y: 0)
        button.subviews.forEach { $0.removeFromSuperview() }
        button.addSubview(view)
    }

    
    @objc func togglePopover(_ sender: AnyObject?) {
        Log.appDelegate.debug("popover click")
        self.globalModel.viewShowing = true
        NSApp.activate(ignoringOtherApps: true)

        if let button = self.statusBarItem.button {
            if AppDelegate.popover.isShown {
                AppDelegate.popover.performClose(sender)
            } else {
                if globalModel.controllerHaveBeenReleased == true {
                    Log.appDelegate.info("rebuilding popover controller after deep sleep")
                    AppDelegate.popover.contentViewController = NSHostingController(rootView: self.contentView.withGlobalEnvironmentObjects())
                    AppDelegate.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY) // to avoid the child windows could not be create in the first time
                }

                if let parentWindow = NSApp.windows.first,
                   let popoverVCWindow = AppDelegate.popover.contentViewController?.view.window,
                   let childWindows = parentWindow.childWindows {
                    if !childWindows.contains(popoverVCWindow) {
                        parentWindow.addChildWindow(popoverVCWindow, ordered: .above)
                    }
                } else {
                    Log.appDelegate.error("Failed to add child window")
                }


                AppDelegate.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                AppDelegate.popover.contentViewController?.view.viewDidMoveToWindow()
                AppDelegate.popover.contentViewController?.view.window?.becomeKey()
                AppDelegate.popover.contentViewController?.view.window?.makeKey()
                // The popover window is cached between shows; pin it to the
                // app appearance so it always matches the Display-tab choice.
                AppDelegate.popover.contentViewController?.view.window?.appearance = NSApp.appearance

                // Belt-and-braces screen clamp. AppKit positions and clamps
                // the popover at `show` time, but the SwiftUI content (and
                // vertical growth from the sparkline) can resize the window
                // after that; the extra width then extends to the right and
                // ends up off-screen when the status item sits near the right
                // end of the menu bar. Shift the final frame back inside the
                // visible area — the arrow just points at a slightly
                // different spot, which every menu-bar popover accepts.
                if let window = AppDelegate.popover.contentViewController?.view.window,
                   let visible = window.screen?.visibleFrame {
                    var frame = window.frame
                    if frame.maxX > visible.maxX {
                        frame.origin.x = visible.maxX - frame.width
                    }
                    if frame.minX < visible.minX {
                        frame.origin.x = visible.minX
                    }
                    if frame.origin != window.frame.origin {
                        window.setFrameOrigin(frame.origin)
                    }
                }

                globalModel.controllerHaveBeenReleased = false
            }
        }
    }

    // MARK: - Notification delegate

    /// Foreground (active) app: still present a banner + list entry + sound
    /// so quota / abnormal-upload alerts are seen. Without this the system
    /// silently keeps the notification in Notification Center.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: - Settings window
    //
    // The macOS 13+ `Settings { }` scene is unavailable because the deployment
    // target is 11.0, so the window is assembled by hand: a plain `NSWindow`
    // hosting `SettingsRootView` (tab bar + selected pane). The tab bar is
    // drawn in SwiftUI rather than using `NSTabViewController`'s toolbar tabs,
    // because AppKit's preference-toolbar selection tints the selected item's
    // icon and label with the system accent and that styling has no override.
    //
    // Reusing the window (vs. a fresh one per click) is deliberate: a new
    // window each time would race with the system window animator and could
    // appear stacked on top of the previous one if the user double-clicks
    // the button. Lazy creation also means a user who never opens Settings
    // pays no memory cost.

    private var settingsWindow: NSWindow?
    /// Selection shared with the hosted view so the window can follow it.
    private var settingsTabSelection: SettingsTabSelection?

    @objc func showSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let selection = SettingsTabSelection()
        settingsTabSelection = selection
        let host = NSHostingController(
            rootView: SettingsRootView(settings: SettingsStore.shared, selection: selection)
        )
        let window = NSWindow(contentViewController: host)
        window.title = Loc.l("Settings")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        settingsWindow = window
        applyPaneSize(for: selection.tab)
        window.center()

        // Follow the pane selection. The resize is deferred a runloop turn:
        // `@Published` fires *before* the property is written (see
        // .trellis/spec/guides/swift-combine-swiftui-pitfalls.md), and resizing
        // the window synchronously inside that notification re-enters AppKit
        // while SwiftUI is mid-update — observed as the window resizing but the
        // pane never changing.
        selection.$tab
            .sink { [weak self] tab in
                DispatchQueue.main.async { self?.applyPaneSize(for: tab) }
            }
            .store(in: &windowTitleCancellables)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.appDelegate.info("settings window opened")
    }

    /// Resize the window to the selected pane's natural size, keeping the top
    /// edge fixed. `contentMinSize` keeps the pane from being clipped if the
    /// user shrinks the window afterwards.
    ///
    /// Deliberately not animated: a tab switch is a jump, not a transition.
    private func applyPaneSize(for tab: SettingsTab) {
        guard let window = settingsWindow else { return }
        let size = NSSize(width: SettingsMetrics.width,
                          height: SettingsMetrics.tabBarHeight + tab.contentHeight)
        window.contentMinSize = size
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - History window
    //
    // Same lazy-window pattern as the settings window: created on first
    // click, reused after. The SwiftUI state inside (filters, range)
    // survives close/reopen because the hosting controller is cached.

    private var historyWindow: NSWindow?

    @objc func showHistoryWindow() {
        if let window = historyWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: HistoryWindowView())
        let window = NSWindow(contentViewController: host)
        window.title = Loc.l("History")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 480))
        window.center()
        historyWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.appDelegate.info("history window opened")
    }

    // MARK: - Notification permission

    /// Ask for notification permission once at launch, when at least one
    /// notifying feature is already enabled.
    ///
    /// The Settings toggles call `requestAuthorization()` only at the moment the
    /// user flips them on, so a toggle that is already on — because it was
    /// enabled in an earlier run — never prompts again. That matters here
    /// because the notification permission is keyed to the app's code-signing
    /// identity, and this fork is ad-hoc signed, so a rebuild is a new identity
    /// and the grant can be lost. Without this the features look enabled but
    /// stay silent, and the only symptom is a log line nobody reads.
    ///
    /// `getNotificationSettings` never prompts; only the `.notDetermined` branch
    /// shows the system dialog. A `.denied` answer is final — the system dialog
    /// will never pop again — so that branch gets the launch alert instead:
    /// an explicit pointer to System Settings, suppressible per user choice
    /// (the Settings panes keep their inline warnings either way).
    private func requestNotificationAuthorizationIfNeeded() {
        let settings = SettingsStore.shared
        let needed = settings.quotaEnabled
            || settings.uploadAlertEnabled
            || settings.cleanupModeRaw == CleanupMode.manualNotification.rawValue
        guard needed else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { current in
            DispatchQueue.main.async {
                switch current.authorizationStatus {
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                        Log.appDelegate.info(
                            "notification authorization requested: granted=\(granted) error=\(error?.localizedDescription ?? "nil")"
                        )
                    }
                case .denied:
                    Log.appDelegate.error(
                        "notifications are denied in System Settings → Notifications → FlowTrace;"
                        + " quota and traffic alerts will not be delivered"
                    )
                    Self.presentLaunchReminderIfNotSuppressed()
                default:
                    Log.appDelegate.info("notification authorization already granted")
                }
            }
        }
    }

    private static let launchReminderSuppressedKey = "notificationLaunchReminderSuppressed"

    /// The launch alert for a denied permission: what breaks (quota alerts,
    /// traffic alerts, retention reminders), where to fix it, and a permanent
    /// opt-out. Opting out writes the suppression key only — the Settings
    /// panes' inline warnings keep working, so this silences the launch prompt
    /// without removing every path to a fix.
    ///
    /// **Suppressed under XCTest.** The test bundle runs inside this app, so
    /// `applicationDidFinishLaunching` executes for real during a test run;
    /// a modal `runModal()` there would hold the main thread hostage and hang
    /// every test that awaits a main-queue callback (measured: two
    /// AlertAndQuotaIntegration tests timed out until this guard was added).
    private static func presentLaunchReminderIfNotSuppressed() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: launchReminderSuppressedKey) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Loc.l("Notifications are turned off")
        alert.informativeText = Loc.l(
            "Quota alerts, traffic alerts and retention reminders cannot be delivered."
                + " Turn on notifications for FlowTrace in System Settings."
        )
        alert.addButton(withTitle: Loc.l("Open System Settings"))
        alert.addButton(withTitle: Loc.l("Don't remind me again"))
        let response = alert.runModal()

        if response == .alertSecondButtonReturn {
            defaults.set(true, forKey: launchReminderSuppressedKey)
            Log.appDelegate.info("launch notification reminder suppressed by user")
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillResignActive(_ aNotification: Notification)
    {
        Log.appDelegate.debug("lost focus")
        self.globalModel.viewShowing = false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Log.appDelegate.info("applicationWillTerminate")
    }

}
