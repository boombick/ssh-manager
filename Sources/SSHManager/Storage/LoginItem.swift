import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for managing "open at login".
/// Stateless — macOS owns the source of truth. We never persist our own copy.
enum LoginItem {
    /// `true` when macOS will launch us at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` when we are registered but the user must still approve us in
    /// System Settings → General → Login Items.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the main app as a login item.
    /// Throws on macOS failure (e.g. app running from a transient location).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
