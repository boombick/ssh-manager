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
        let config: AppConfig
        do {
            config = try store.load()
        } catch {
            NSLog("SSHManager: failed to load config: \(error). Starting with empty list.")
            config = AppConfig()
        }

        supervisor = TunnelSupervisor(store: store, config: config)
        mainWindow = MainWindowController(supervisor: supervisor)
        menuBar = MenuBarController(supervisor: supervisor) { [weak self] in
            self?.mainWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisor?.shutdownForQuit()
    }
}
