import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var supervisor: TunnelSupervisor!
    private var menuBar: MenuBarController!
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Paths.ensureSupportDirectory()
        } catch {
            NSLog("SSHManager: failed to create support directory: \(error)")
        }

        let store = ConfigStore()
        let connections: [Connection]
        do {
            connections = try store.load()
        } catch {
            NSLog("SSHManager: failed to load config: \(error). Starting with empty list.")
            connections = []
        }

        supervisor = TunnelSupervisor(store: store, connections: connections)
        mainWindow = MainWindowController(supervisor: supervisor)
        menuBar = MenuBarController(supervisor: supervisor) { [weak self] in
            self?.mainWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor?.stopAll()
    }
}
