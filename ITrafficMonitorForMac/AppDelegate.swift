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
        self.contentView = ContentView()
        let statusBarView = AnyView(StatusBarView())
        self.network = Network()
        
        // Create the popover. Width 340 / height 460 fits the new header
        // (header + search + scroll + history); the upstream's 300x420 sized
        // for the old single-section layout.
        AppDelegate.popover = NSPopover()
        AppDelegate.popover.contentSize = NSSize(width: 340, height: 460)
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
        AppLogger.appDelegate.debug("popover click")
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
                    AppLogger.appDelegate.error("Failed to add child window")
                }


                AppDelegate.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                AppDelegate.popover.contentViewController?.view.viewDidMoveToWindow()
                AppDelegate.popover.contentViewController?.view.window?.becomeKey()
                AppDelegate.popover.contentViewController?.view.window?.makeKey()

                globalModel.controllerHaveBeenReleased = false
            }
        }
    }

    func applicationWillResignActive(_ aNotification: Notification)
    {
        AppLogger.appDelegate.debug("lost focus")
        self.globalModel.viewShowing = false
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        AppLogger.appDelegate.info("applicationWillTerminate")
    }

}
