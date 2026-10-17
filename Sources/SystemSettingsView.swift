import Cocoa
import SwiftUI
import Combine

struct SystemSettingsView: View {
    @ObservedObject var mapping: MappingController
    @ObservedObject var startup: StartupController
    private let refreshTimer = Timer.publish(every:3,on:.main,in:.common).autoconnect()
    var busy: Bool { mapping.running || mapping.starting }
    func text(_ key: String) -> String { NSLocalizedString(key,comment:"") }
    func refresh() { mapping.refreshSystemChecks(); startup.refresh() }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                PageHeading(eyebrow:"SYSTEM",title:text("settings.title"),detail:text("settings.detail"))
                HStack {
                    Button { refresh() } label: { Label(text("settings.refresh"),systemImage:"arrow.clockwise") }
                    if mapping.checkingService { ProgressView().controlSize(.small) }
                    Spacer()
                }
                ControlCard(title:text("settings.permissions")) {
                    HStack {
                        checkRow(text("settings.accessibility"),state:mapping.accessibilityGranted ? "granted" : "denied",good:mapping.accessibilityGranted)
                        Button(text("settings.authorize")) { mapping.requestPermissions(); mapping.openPermissionSettings(input:false) }
                    }
                    Divider()
                    HStack {
                        checkRow(text("settings.input"),state:mapping.serviceInputAccess.rawValue,good:mapping.serviceInputAccess == .granted)
                        Button(text("startup.open_settings")) { mapping.openPermissionSettings(input:true) }
                        Button(text("settings.service.show")) { mapping.showInputService() }
                            .disabled(!FileManager.default.fileExists(atPath:InputService.appPath))
                    }
                    Text(text("settings.permissions.note")).font(.caption).foregroundStyle(.secondary)
                }
                ControlCard(title:text("settings.service")) {
                    HStack {
                        checkRow(text("settings.service.status"),state:"service."+mapping.serviceState.rawValue,good:mapping.serviceState == .ready)
                        Button(text("settings.service.install")) { mapping.installInputService() }.disabled(busy || mapping.checkingService)
                        Button(text("service.remove")) { mapping.uninstallInputService() }.disabled(busy || mapping.checkingService)
                    }
                    Text(text("settings.service.note")).font(.caption).foregroundStyle(.secondary)
                    Text(mapping.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ControlCard(title:text("startup.card_title")) {
                    checkRow(text("settings.login.status"),state:"login."+startup.state.rawValue,good:startup.state == .enabled)
                    HStack {
                        Toggle(text("startup.open_at_login"),isOn:Binding(get:{startup.requested},set:{startup.setEnabled($0)}))
                        Spacer()
                        Button(text("startup.open_settings")) { startup.openSettings() }
                    }
                    if !startup.error.isEmpty { Text(startup.error).font(.caption).foregroundStyle(.orange) }
                    Text(text("settings.login.note")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle(text("mapping.auto_start_toggle"),isOn:$mapping.autoStart)
                    Text(text("settings.mapping.startup.note")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    func checkRow(_ title: String,state: String,good: Bool) -> some View {
        HStack(spacing:10) {
            Image(systemName:good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(good ? RazerTheme.green : .orange)
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.system(size:13,weight:.medium))
                Text(text("settings."+state)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
