import Cocoa
import ServiceManagement

final class StartupController: ObservableObject {
    @Published private(set) var requested = false
    @Published private(set) var detail = ""
    init() {
        refresh()
    }
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: requested = true; detail = "登录启动已启用"
        case .requiresApproval: requested = true; detail = "登录启动等待系统批准，请查看登录项设置"
        case .notRegistered: requested = false; detail = "登录启动已关闭"
        case .notFound: requested = false; detail = "启动项未就绪，请保持应用位于固定位置"
        @unknown default: requested = false; detail = "无法确认登录启动状态"
        }
    }
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notFound { try? SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh(); detail = "启动项设置失败：\(error.localizedDescription)"
        }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
