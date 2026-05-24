import AppKit
import SwiftUI

/// Owns the single "Manage Connections" window. Lazily created on first show().
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let supervisor: TunnelSupervisor

    init(supervisor: TunnelSupervisor) {
        self.supervisor = supervisor
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = ConnectionListView(supervisor: supervisor)
        let hosting = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: hosting)
        w.title = "SSH Manager"
        w.setContentSize(NSSize(width: 720, height: 480))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.minSize = NSSize(width: 520, height: 320)
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
