import Cocoa
import ServiceManagement

enum LoginLaunchState: String {
    case enabled, approval, disabled, unavailable, unknown
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .approval
        case .notRegistered: self = .disabled
        case .notFound: self = .unavailable
        @unknown default: self = .unknown
        }
    }
    var requested: Bool { self == .enabled || self == .approval }
}
final class StartupController: ObservableObject {
    @Published private(set) var state = LoginLaunchState.unknown
    @Published private(set) var error = ""
    var requested: Bool { state.requested }
    var detail: String { error.isEmpty ? NSLocalizedString("settings.login."+state.rawValue,comment:"") : error }
    init() { refresh() }
    func refresh() { state = LoginLaunchState(SMAppService.mainApp.status) }
    func setEnabled(_ enabled: Bool) {
        error = ""
        do {
            if enabled {
                if SMAppService.mainApp.status == .notFound { try? SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh(); self.error = NSLocalizedString("settings.login.error",comment:"")+error.localizedDescription
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
