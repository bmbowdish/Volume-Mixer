import Foundation
import ServiceManagement

/// Open-at-login via macOS's Login Items (System Settings → General → Login Items).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    private let setupKey = "didSetUpLoginItem"

    /// Turns it on the first time the app runs; after that, respects the user's choice.
    func setUpOnFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: setupKey) {
            UserDefaults.standard.set(true, forKey: setupKey)
            setEnabled(true)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
