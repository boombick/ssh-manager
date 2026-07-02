import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let supervisor: TunnelSupervisor
    private let onOpenWindow: () -> Void
    private let menu = NSMenu()

    init(supervisor: TunnelSupervisor, onOpenWindow: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.supervisor = supervisor
        self.onOpenWindow = onOpenWindow
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "network",
                                accessibilityDescription: "SSH Manager")
            image?.isTemplate = true
            button.image = image
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    // Built lazily each time the menu is about to open, so the items reflect
    // current state without re-creating the menu (which causes tracking glitches).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if supervisor.connections.isEmpty {
            let item = NSMenuItem(title: "No connections — edit config.json",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for c in supervisor.connections {
                let state = supervisor.engine(for: c.id)?.state ?? .stopped
                let counters = supervisor.stats[c.id] ?? ByteCounters()
                let item = NSMenuItem(title: title(for: c, state: state, counters: counters),
                                      action: #selector(toggleConnection(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = c.id
                item.state = state.isRunning ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addMasterPortSubmenu(to: menu)
        menu.addItem(.separator())

        let manageItem = NSMenuItem(title: "Manage Connections…",
                                    action: #selector(openWindow),
                                    keyEquivalent: "m")
        manageItem.target = self
        menu.addItem(manageItem)

        let reloadItem = NSMenuItem(title: "Reload Config",
                                    action: #selector(reload),
                                    keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let editItem = NSMenuItem(title: "Edit config.json…",
                                  action: #selector(editConfig),
                                  keyEquivalent: "e")
        editItem.target = self
        menu.addItem(editItem)

        let logsItem = NSMenuItem(title: "Open Logs Folder",
                                  action: #selector(openLogs),
                                  keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(.separator())

        let debugItem = NSMenuItem(title: "Debug Mode",
                                   action: #selector(toggleDebugMode),
                                   keyEquivalent: "")
        debugItem.target = self
        debugItem.state = DebugTrace.shared.isEnabled ? .on : .off
        menu.addItem(debugItem)

        let reportItem = NSMenuItem(title: "Save Debug Report…",
                                    action: #selector(saveDebugReport),
                                    keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SSH Manager",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func title(for c: Connection, state: TunnelState, counters: ByteCounters) -> String {
        let glyph: String
        switch state {
        case .stopped:      glyph = "○"
        case .running:      glyph = "●"
        case .reconnecting: glyph = "↻"
        case .failed:       glyph = "⚠"
        }
        let badge: String
        switch c.type {
        case .dynamic:
            badge = "SOCKS :\(c.listenPort)"
        case .local:
            badge = "L :\(c.listenPort) → \(c.remoteHost ?? "?"):\(c.remotePort ?? 0)"
        case .remote:
            badge = "R :\(c.listenPort) → \(c.remoteHost ?? "?"):\(c.remotePort ?? 0)"
        }

        var line = "\(glyph)  \(c.name)  ·  \(badge)"
        if state.isRunning || counters.up > 0 || counters.down > 0 {
            line += "   ↑ \(formatBytes(counters.up))   ↓ \(formatBytes(counters.down))"
        }
        return line
    }

    /// "Master Port :1080 → work" submenu: radio list of SOCKS connections
    /// plus Off. One click re-points the master port.
    private func addMasterPortSubmenu(to menu: NSMenu) {
        let selected = supervisor.masterConnectionId
        let selectedName = supervisor.connections.first { $0.id == selected }?.name

        let title = "Master Port :\(supervisor.masterPort) → \(selectedName ?? "Off")"
        let rootItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let offItem = NSMenuItem(title: "Off",
                                 action: #selector(selectMasterTarget(_:)),
                                 keyEquivalent: "")
        offItem.target = self
        offItem.state = selected == nil ? .on : .off
        submenu.addItem(offItem)
        submenu.addItem(.separator())

        let candidates = supervisor.connections.filter { $0.type == .dynamic }
        if candidates.isEmpty {
            let empty = NSMenuItem(title: "No SOCKS connections", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for c in candidates {
            let item = NSMenuItem(title: "\(c.name)  ·  :\(c.listenPort)",
                                  action: #selector(selectMasterTarget(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            item.state = c.id == selected ? .on : .off
            submenu.addItem(item)
        }

        rootItem.submenu = submenu
        menu.addItem(rootItem)
    }

    @objc private func toggleConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        supervisor.toggle(id: id)
    }

    @objc private func selectMasterTarget(_ sender: NSMenuItem) {
        let id = sender.representedObject as? UUID
        do {
            try supervisor.selectMaster(id: id)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Master port switch failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openWindow() {
        onOpenWindow()
    }

    @objc private func reload() {
        supervisor.reload()
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(Paths.configFile)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(Paths.logsDirectory)
    }

    @objc private func toggleDebugMode() {
        DebugTrace.shared.setEnabled(!DebugTrace.shared.isEnabled)
    }

    @objc private func saveDebugReport() {
        do {
            let url = try DebugReport.save(supervisor: supervisor)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSLog("SSHManager: debug report failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could not save debug report"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
