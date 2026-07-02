import AppKit
import SwiftUI

@MainActor
final class UsageDashboardWindowController {
    static let shared = UsageDashboardWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hostingController = NSHostingController(rootView: UsageDashboardView())
            // Surface the SwiftUI NavigationSplitView title and toolbar through the
            // AppKit window while the full-size content view keeps the sidebar glass
            // running behind the titlebar.
            hostingController.sceneBridgingOptions = [.all]
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MeterBar Usage"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            // Unified transparent chrome so the native toolbar/titlebar glass
            // reads as one surface with the sidebar (MacSweep-style native look).
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 900, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
