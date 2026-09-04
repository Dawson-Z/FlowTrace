//
//  AppDelegate.swift
//  ITrafficMonitorForMac
//
//  Created by f.zou on 2021/5/19.
//

import Cocoa
import SwiftUI

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

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
        
        // Create the popover. Width 340 / height 480 fits the wider header
        // (header + search + sort + scroll + history + summary row); the
        // upstream's 300x420 sized for the old single-section layout.
        AppDelegate.popover = NSPopover()
        AppDelegate.popover.contentSize = NSSize(width: 340, height: 480)
        AppDelegate.popover.behavior = .transient
//        popover.contentViewController = NSHostingController(rootView: contentView.withGlobalEnvironmentObjects())
        
//        NSApp.activate(ignoringOtherApps: true)
        
        AppDelegate.popover.behavior = .transient
        AppDelegate.popover.animates = false
        // Create the status item
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))

        if let button = self.statusBarItem.button {
            button.action = #selector(togglePopover(_:))
            let view = NSHostingView(rootView: statusBarView)
            view.setFrameSize(NSSize(width: 60, height: NSStatusBar.system.thickness))            
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(view)
            self.statusBarItem.length = 60
        }
        
        self.network.startListenNetwork()
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
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.appDelegate.info("settings window opened")
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
