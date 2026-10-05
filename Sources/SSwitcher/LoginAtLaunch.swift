import AppKit
import ServiceManagement

/// Reading status never registers anything. Only the user's menu action calls
/// Apple's main-app login-item API; no helper, plist or launch daemon is added.
final class LoginAtLaunch {
    private let queue = DispatchQueue(label: "com.tonydanzza.SSwitcher.login-item", qos: .utility)
    private(set) var isChanging = false
    private(set) var lastError: String?
    var status: SMAppService.Status { SMAppService.mainApp.status }
    var state: NSControl.StateValue {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }
    var statusDescription: String {
        switch status {
        case .enabled: return "Автозапуск включён"
        case .requiresApproval: return "Подтвердите автозапуск в настройках macOS"
        case .notRegistered: return "Автозапуск выключен"
        case .notFound: return "Автозапуск: macOS не нашла службу"
        @unknown default: return "Статус автозапуска неизвестен"
        }
    }
    func toggle(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isChanging else { return }
        let enable = status != .enabled && status != .requiresApproval
        isChanging = true
        lastError = nil
        queue.async {
            let error: String?
            do {
                if enable { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                error = nil
            } catch let failure { error = failure.localizedDescription }
            DispatchQueue.main.async {
                self.isChanging = false
                self.lastError = error.map { "Не удалось изменить автозапуск: " + $0 }
                completion()
            }
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
