//
//  AppDelegate.swift
//  ITrafficMonitorForMac
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
        // ~/Library/Logs/iTrafficPlus.log. See Feature/Logging/AppLogger.swift
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
            Log.appDelegate.info("history persistence attached at \(persistence.dbURL.path); retention=\(Int(retention/86400))d")
        } else {
            Log.appDelegate.error("history persistence failed to open; falling back to in-memory only")
        }

        self.contentView = ContentView()
        let statusBarView = AnyView(StatusBarView())
        self.network = Network()
        
        // Create the popover. Width 340 / height 520 fits the wider header
        // (header + search + sort + scroll + interface + history + summary
        // row); the upstream's 300x420 sized for the old single-section.
        AppDelegate.popover = NSPopover()
        AppDelegate.popover.contentSize = NSSize(width: 340, height: 520)
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

            // Extra segments (today/month totals) change the ideal width —
            // re-measure whenever those settings flip.
            SettingsStore.shared.$showTodayInMenuBar
                .combineLatest(SettingsStore.shared.$showMonthInMenuBar)
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

        self.network.startListenNetwork()
    }

    // Menu-bar width mirrors StatusBarView's column layout:
    //   padding 6 + rate column 55 (if any rate) + totals column 34 (if any)
    //   — never wider than the content, never clipping it.
    private var statusBarLength: CGFloat {
        var width: CGFloat = 6
        let anyRate = SettingsStore.shared.showDownloadInStatusBar
            || SettingsStore.shared.showUploadInStatusBar
        let anyTotal = SettingsStore.shared.showTodayInMenuBar
            || SettingsStore.shared.showMonthInMenuBar
        if anyRate { width += 55 }
        if anyTotal { width += 34 }
        return max(width, 40)
    }

    private var statusBarCancellables: Set<AnyCancellable> = []

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
                    AppLogger.appDelegate.info("rebuilding popover controller after deep sleep")
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
    // We do not use the macOS 13+ `Settings { }` scene because the deployment
    // target is 11.0. Instead, the ⚙ button in `ContentView`'s header fires
    // this action, which lazily creates a single `NSWindow` and reuses it on
    // every subsequent click.
    //
    // Reusing the window (vs. a fresh one per click) is deliberate: a new
    // window each time would race with the system window animator and could
    // appear stacked on top of the previous one if the user double-clicks
    // the button. Lazy creation also means a user who never opens Settings
    // pays no memory cost.

    private var settingsWindow: NSWindow?

    @objc func showSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(settings: SettingsStore.shared)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = Loc.l("Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.appDelegate.info("settings window opened")
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

    func applicationWillResignActive(_ aNotification: Notification)
    {
        Log.appDelegate.debug("lost focus")
        self.globalModel.viewShowing = false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Log.appDelegate.info("applicationWillTerminate")
    }

}
