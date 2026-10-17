import Cocoa
import SwiftUI
import IOKit.hid
import Combine

// MARK: - LocaleManager: in-app language switching

final class LocaleManager: ObservableObject {
    static let shared = LocaleManager()
    static let supportedLanguages = ["zh-Hans", "zh-Hant", "en", "ja"]
    static let userDefaultsKey = "appLanguage"

    @Published private(set) var currentLanguage: String

    private var cancellables = Set<AnyCancellable>()
    /// Incremented on every change so SwiftUI views keyed on this value rebuild.
    private(set) var revision: UInt64 = 0

    init() {
        Self.installSwizzle()
        let saved = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
        let initial = Self.supportedLanguages.contains(saved) ? saved : "en"
        self.currentLanguage = initial
        Self.applyBundleOverride(initial)
    }

    func select(_ code: String) {
        guard Self.supportedLanguages.contains(code), code != currentLanguage else { return }
        currentLanguage = code
        UserDefaults.standard.set(code, forKey: Self.userDefaultsKey)
        Self.applyBundleOverride(code)
        revision &+= 1
        objectWillChange.send()
        NotificationCenter.default.post(name: .appLanguageDidChange, object: self)
    }

    /// Names shown in the language menu, resolved through the CURRENT bundle override
    /// so each language is written in its own script.
    func menuItems() -> [(code: String, name: String)] {
        Self.supportedLanguages.map { code in
            let lproj = Bundle.main.path(forResource: code, ofType: "lproj")
            let bundle = lproj.flatMap(Bundle.init(path:)) ?? Bundle.main
            let name = bundle.localizedString(forKey: "lang.\(code)", value: code, table: nil)
            return (code, name)
        }
    }

    // MARK: - Bundle override

    static var overrideBundle: Bundle?

    private static func applyBundleOverride(_ code: String) {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return }
        overrideBundle = bundle
    }

    /// Install the swizzle exactly once. Must run before any NSLocalizedString call.
    static func installSwizzle() {
        struct Once { static var token: Int = 0 }
        objc_sync_enter(Once.self)
        defer { objc_sync_exit(Once.self) }
        guard objc_getAssociatedObject(Bundle.self, &Once.token) == nil else { return }
        objc_setAssociatedObject(Bundle.self, &Once.token, true, .OBJC_ASSOCIATION_RETAIN)

        guard let originalMethod = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
              let swizzledMethod = class_getInstanceMethod(Bundle.self, #selector(Bundle.tl_swizzled_localizedString(forKey:value:table:))) else {
            return
        }

        // Save the original implementation before swizzling
        originalImp = method_getImplementation(originalMethod)

        // Exchange implementations
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    /// Original implementation of Bundle.localizedString, saved before swizzling
    nonisolated(unsafe) static var originalImp: IMP?
}

extension Bundle {
    @objc func tl_swizzled_localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        // Try override bundle first (but call the ORIGINAL implementation on it, not the swizzled one)
        if let override = LocaleManager.overrideBundle,
           let originalImp = LocaleManager.originalImp {
            // Cast the IMP to the correct function type and call it directly
            typealias LocalizedStringFunc = @convention(c) (Bundle, Selector, String, String?, String?) -> String
            let originalFunc = unsafeBitCast(originalImp, to: LocalizedStringFunc.self)
            let resolved = originalFunc(override, #selector(Bundle.localizedString(forKey:value:table:)), key, nil, tableName)
            if resolved != key { return resolved }
        }

        // Fall back to original implementation on self
        if let originalImp = LocaleManager.originalImp {
            typealias LocalizedStringFunc = @convention(c) (Bundle, Selector, String, String?, String?) -> String
            let originalFunc = unsafeBitCast(originalImp, to: LocalizedStringFunc.self)
            return originalFunc(self, #selector(Bundle.localizedString(forKey:value:table:)), key, value, tableName)
        }

        // Ultimate fallback (should never reach here)
        return key
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

enum LightEffect: Int, Codable, CaseIterable, Identifiable {
    case off = 0, solid = 1, spectrum = 3
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .off: return NSLocalizedString("effect.off", comment: "")
        case .solid: return NSLocalizedString("effect.solid", comment: "")
        case .spectrum: return NSLocalizedString("effect.spectrum", comment: "")
        }
    }
}
struct RGB: Codable, Equatable {
    var red: Double; var green: Double; var blue: Double
    var valid: Bool { [red,green,blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var color: Color { Color(red:red,green:green,blue:blue) }
    static let defaults = [RGB(red:0.27,green:1,blue:0), RGB(red:0,green:0.7,blue:1), RGB(red:0.7,green:0.1,blue:1)]
}
struct LightProfile: Codable, Equatable {
    var red: Double; var green: Double; var blue: Double; var effect: LightEffect
    var location: UInt32?
    var cycleColors: [RGB]? = nil
    var cycleSeconds: Double? = nil
    var customCycle: Bool? = nil
    var palette: [RGB] { cycleColors ?? RGB.defaults }
    var duration: Double { cycleSeconds ?? 8 }
    var valid: Bool {
        RGB(red:red,green:green,blue:blue).valid && (2...8).contains(palette.count)
        && palette.allSatisfy(\.valid) && duration.isFinite && (2...60).contains(duration)
    }
    func frame(elapsed: TimeInterval) -> LightProfile {
        guard effect == .spectrum, customCycle == true else { return self }
        let position = max(0,elapsed).truncatingRemainder(dividingBy:duration) / duration * Double(palette.count)
        let index = Int(position), fraction = position - Double(index)
        let a = palette[index], b = palette[(index+1) % palette.count]
        var p = self; p.effect = .solid
        p.red = a.red + (b.red-a.red)*fraction; p.green = a.green + (b.green-a.green)*fraction; p.blue = a.blue + (b.blue-a.blue)*fraction
        return p
    }
}
enum LightProtocol {
    static let vendor = 5426, product = 555
    static func matching(location: UInt32? = nil) -> [String:Any] {
        var d: [String:Any] = [kIOHIDVendorIDKey:vendor,kIOHIDProductIDKey:product]
        if let location = location { d[kIOHIDLocationIDKey] = location }
        return d
    }
    static func accepts(vendor: Int, product: Int, location: UInt32, selected: UInt32) -> Bool {
        selected != 0 && vendor == self.vendor && product == self.product && location == selected
    }
    static func packet(_ p: LightProfile, volatile: Bool = false) -> [UInt8] {
        precondition(p.valid)
        let args: [UInt8]
        switch p.effect {
        case .off: args = [1,5,0,0,0,0]
        case .spectrum: args = [1,5,3,0,0,0]
        case .solid: args = [1,5,1,0,0,1] + [p.red,p.green,p.blue].map { UInt8(($0*255).rounded()) }
        }
        var b = [UInt8](repeating:0,count:90)
        b[1] = 0x1f; b[5] = UInt8(args.count); b[6] = 15; b[7] = 2
        for (i,v) in args.enumerated() { b[8+i] = v }
        if volatile { b[8] = 0 }
        b[88] = b[2..<88].reduce(0,^)
        return b
    }
    static func acknowledges(_ response: [UInt8], length: Int) -> Bool {
        length == 90 && response.count == 90 && response[0] == 2 && response[1] == 0x1f && response[6] == 15 && response[7] == 2 && response[88] == response[2..<88].reduce(0,^)
    }
}
func hidError(_ code: IOReturn) -> String { String(format:"0x%08x",UInt32(bitPattern:code)) }

enum LightHardware {
    static func devices(location: UInt32? = nil) -> [IOHIDDevice] {
        let m = IOHIDManagerCreate(kCFAllocatorDefault,0)
        IOHIDManagerSetDeviceMatching(m,LightProtocol.matching(location:location) as CFDictionary)
        return (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>).map(Array.init) ?? []
    }
    static func location(_ d: IOHIDDevice) -> UInt32 { (IOHIDDeviceGetProperty(d,kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value ?? 0 }
    static func number(_ d: IOHIDDevice,_ key: String) -> Int { (IOHIDDeviceGetProperty(d,key as CFString) as? NSNumber)?.intValue ?? 0 }
    static func apply(_ p: LightProfile, location: UInt32, volatile: Bool = false) -> (ok:Bool,message:String) {
        guard p.valid, location != 0 else { return (false,NSLocalizedString("hw.please_select_device_and_color", comment: "")) }
        let packet = LightProtocol.packet(p,volatile:volatile)
        let ds = devices(location:location)
        guard !ds.isEmpty else { return (false,NSLocalizedString("hw.device_disconnected_waiting", comment: "")) }
        var response = [UInt8](repeating:0,count:90)
        var length: UInt32 = 0
        let result = packet.withUnsafeBufferPointer { request in
            response.withUnsafeMutableBufferPointer { reply in
                tartarusLightTransfer(location,request.baseAddress!,reply.baseAddress!,&length)
            }
        }
        if result == kIOReturnSuccess && LightProtocol.acknowledges(response,length:Int(length)) {
            return (true,String(format: NSLocalizedString("hw.device_acknowledged", comment: ""), p.effect.name))
        }
        return (false,String(format: NSLocalizedString("hw.usb_not_acknowledged", comment: ""), hidError(result), Int(response[0]), Int(length)))

    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let controller = LightController()
    let startup = StartupController()
    let mapping = MappingController()
    let locale = LocaleManager.shared
    private var observers: [NSObjectProtocol] = []
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.mapping.stop(); self?.controller.suspend() })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.controller.resume() })
        }
        if mapping.autoStart { DispatchQueue.main.async { [weak self] in self?.mapping.start() } }
        setupStatusBar()
        observers.append(NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildStatusMenu()
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.hideMainWindow() }
    }
    func applicationWillTerminate(_ notification: Notification) { controller.suspend(); mapping.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button,
           let image = NSImage(systemSymbolName: "bolt.shield.fill", accessibilityDescription: "Tartarus Light") {
            image.isTemplate = true
            button.image = image
        }
        rebuildStatusMenu()
    }
    private func rebuildStatusMenu() {
        let menu = NSMenu()
        let showItem = NSMenuItem(title: NSLocalizedString("menu.show", comment: ""), action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let langItem = NSMenuItem(title: NSLocalizedString("menu.language", comment: ""), action: nil, keyEquivalent: "")
        let langSubmenu = NSMenu()
        for (code, name) in locale.menuItems() {
            let item = NSMenuItem(title: name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            if code == locale.currentLanguage { item.state = .on }
            langSubmenu.addItem(item)
        }
        langItem.submenu = langSubmenu
        menu.addItem(langItem)

        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: NSLocalizedString("menu.about", comment: ""), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let quitItem = NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }
    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        locale.select(code)
    }
    private func hideMainWindow() {
        guard let window = NSApplication.shared.windows.first else { return }
        mainWindow = window
        window.delegate = self
        window.orderOut(nil)
    }
    @objc func showMainWindow() {
        guard let window = mainWindow ?? NSApplication.shared.windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Harisucici\nEmail: harisucici@gmail.com\nLine: +81 7092401286",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
extension Delegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
struct RootView: View {
    let delegate: Delegate
    @ObservedObject var mapping: MappingController
    @ObservedObject var locale: LocaleManager
    init(delegate: Delegate) {
        self.delegate = delegate
        mapping = delegate.mapping
        locale = delegate.locale
    }
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                Image(systemName:"bolt.shield.fill").font(.system(size:30)).foregroundStyle(RazerTheme.green).padding(.bottom,12)
                Text("TARTARUS").font(.system(size:16,weight:.black,design:.monospaced)).tracking(2)
                Text("DEVICE CONTROL").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1.5).foregroundStyle(.secondary)
                Rectangle().fill(RazerTheme.border).frame(height:1).padding(.vertical,22)
                navigation(NSLocalizedString("nav.lights", comment: ""),icon:"lightbulb.led",tab:0)
                navigation(NSLocalizedString("nav.mapping", comment: ""),icon:"keyboard",tab:1)
                Spacer()
                languagePicker
                Text("TARTARUS V2").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(RazerTheme.green)
                Text(NSLocalizedString("sidebar.version", comment: "")).font(.system(size:10)).foregroundStyle(.secondary)
            }.padding(22).frame(width:186).background(Color.black.opacity(0.35))
            Rectangle().fill(RazerTheme.border).frame(width:1)
            Group {
                if mapping.selectedTab == 0 { ContentView(c:delegate.controller,startup:delegate.startup) }
                else { MappingView(m:delegate.mapping) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:1120,minHeight:790).background(RazerTheme.background)
        .preferredColorScheme(.dark).tint(RazerTheme.green)
        .id(locale.revision)
        .onAppear { if mapping.autoStart { mapping.selectedTab = 1 } }
    }
    var languagePicker: some View {
        VStack(alignment:.leading, spacing:4) {
            Text(NSLocalizedString("sidebar.language_label", comment: ""))
                .font(.system(size:9, weight:.medium, design:.monospaced))
                .tracking(1)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(LocaleManager.supportedLanguages, id: \.self) { code in
                    Button {
                        locale.select(code)
                    } label: {
                        HStack {
                            Text(languageName(for: code))
                            if code == locale.currentLanguage {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(currentLanguageName())
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .font(.system(size: 11))
                .foregroundStyle(RazerTheme.green)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.top, 8)
    }
    func currentLanguageName() -> String {
        languageName(for: locale.currentLanguage)
    }
    func languageName(for code: String) -> String {
        let items = locale.menuItems()
        return items.first(where: { $0.code == code })?.name ?? code
    }
    func navigation(_ title:String,icon:String,tab:Int) -> some View {
        Button { mapping.selectedTab = tab } label: {
            HStack(spacing:10) {
                Image(systemName:icon).frame(width:18)
                Text(title).font(.system(size:13,weight:.medium)); Spacer()
                if mapping.selectedTab == tab { RoundedRectangle(cornerRadius:1).fill(RazerTheme.green).frame(width:3,height:14) }
            }.padding(12).foregroundStyle(mapping.selectedTab == tab ? RazerTheme.green : .secondary)
                .background(mapping.selectedTab == tab ? RazerTheme.green.opacity(0.09) : .clear,in:RoundedRectangle(cornerRadius:7))
        }.buttonStyle(.plain)
    }
}
struct LightApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene { WindowGroup { RootView(delegate:delegate) } }
}
@main enum EntryPoint {
    static func main() {
        // Dispatch before SwiftUI and its delegate can initialize. The privileged
        // role never creates a UI or reads the user's profile files.
        if CommandLine.arguments.dropFirst().contains(ReaderInvocation.flag) { InputReaderMain.main(); return }
        if CommandLine.arguments == [CommandLine.arguments[0],"--self-test"] { runCoreChecks(); return }
        guard geteuid() != 0, CommandLine.arguments.count == 1 else { fputs("Unsupported invocation.\n",stderr); exit(64) }
        LightApp.main()
    }
}
