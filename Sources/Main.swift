import Cocoa
import SwiftUI
import IOKit.hid

enum LightEffect: Int, Codable, CaseIterable, Identifiable {
    case off = 0, solid = 1, spectrum = 3
    var id: Int { rawValue }
    var name: String {
        switch self { case .off: return "关闭"; case .solid: return "固定颜色"; case .spectrum: return "光谱循环" }
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
        guard p.valid, location != 0 else { return (false,"请选择已连接的设备和有效颜色") }
        let packet = LightProtocol.packet(p,volatile:volatile)
        let ds = devices(location:location)
        guard !ds.isEmpty else { return (false,"设备已断开，等待重新连接") }
        var response = [UInt8](repeating:0,count:90)
        var length: UInt32 = 0
        let result = packet.withUnsafeBufferPointer { request in
            response.withUnsafeMutableBufferPointer { reply in
                tartarusLightTransfer(location,request.baseAddress!,reply.baseAddress!,&length)
            }
        }
        if result == kIOReturnSuccess && LightProtocol.acknowledges(response,length:Int(length)) {
            return (true,"设备已确认 · "+p.effect.name)
        }
        return (false,"USB 灯光未确认：\(hidError(result))，设备状态 \(response[0])，回应长度 \(length)。")

    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let controller = LightController()
    let startup = StartupController()
    let mapping = MappingController()
    private var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.mapping.stop(); self?.controller.suspend() })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.controller.resume() })
        }
        if mapping.autoStart { DispatchQueue.main.async { [weak self] in self?.mapping.start() } }
    }
    func applicationWillTerminate(_ notification: Notification) { controller.suspend(); mapping.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct RootView: View {
    let delegate: Delegate
    @ObservedObject var mapping: MappingController
    init(delegate: Delegate) { self.delegate = delegate; mapping = delegate.mapping }
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                Image(systemName:"bolt.shield.fill").font(.system(size:30)).foregroundStyle(RazerTheme.green).padding(.bottom,12)
                Text("TARTARUS").font(.system(size:16,weight:.black,design:.monospaced)).tracking(2)
                Text("DEVICE CONTROL").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1.5).foregroundStyle(.secondary)
                Rectangle().fill(RazerTheme.border).frame(height:1).padding(.vertical,22)
                navigation("灯光效果",icon:"lightbulb.led",tab:0)
                navigation("按键映射",icon:"keyboard",tab:1)
                Spacer()
                Text("TARTARUS V2").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(RazerTheme.green)
                Text("本地设备控制 · v0.5.1").font(.system(size:10)).foregroundStyle(.secondary)
            }.padding(22).frame(width:186).background(Color.black.opacity(0.35))
            Rectangle().fill(RazerTheme.border).frame(width:1)
            Group {
                if mapping.selectedTab == 0 { ContentView(c:delegate.controller,startup:delegate.startup) }
                else { MappingView(m:delegate.mapping) }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(minWidth:1120,minHeight:790).background(RazerTheme.background)
        .preferredColorScheme(.dark).tint(RazerTheme.green)
        .onAppear { if mapping.autoStart { mapping.selectedTab = 1 } }
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
