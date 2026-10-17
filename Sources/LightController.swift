import Cocoa
import SwiftUI
import Combine

struct CycleStop: Identifiable {
    let id = UUID()
    var rgb: RGB
}

final class LightController: ObservableObject {
    @Published var red = 0.27
    @Published var green = 1.0
    @Published var blue = 0.0
    @Published var effect: LightEffect = .solid
    @Published private(set) var cycleStops = RGB.defaults.map { CycleStop(rgb:$0) }
    var cycleColors: [RGB] { cycleStops.map(\.rgb) }
    @Published var cycleSeconds = 8.0
    @Published var customCycle = false
    @Published var locations: [UInt32] = []
    @Published var selectedLocation: UInt32 = 0
    @Published private(set) var busy = false
    @Published var status = "等待连接 Tartarus V2"
    @Published private(set) var preview = RGB.defaults[0]
    private var changes: AnyCancellable?
    private var ticker: Timer?
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label:"local.tartarus.lighting",qos:.userInitiated)
    private var generation = 0
    private var cycleStart: TimeInterval = 0
    private var cycling = false
    private var refreshAt: TimeInterval = 0
    private var sent: LightProfile?
    private var suspended = false
    var profile: LightProfile { LightProfile(red:red,green:green,blue:blue,effect:effect,location:selectedLocation,cycleColors:cycleColors,cycleSeconds:cycleSeconds,customCycle:customCycle) }
    var connected: Bool { locations.contains(selectedLocation) && selectedLocation != 0 }
    var path: URL { URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/TartarusLight/lights.json") }
    init(loadProfile: Bool = true) {
        guard loadProfile else { return }
        load(); detect()
        changes = objectWillChange.sink { [weak self] in
            // Published sends before mutation; compare the complete profile on the next turn.
            DispatchQueue.main.async { self?.scheduleIfChanged() }
        }
        ticker = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!,forMode:.common)
        scheduleIfChanged()
    }
    deinit { ticker?.invalidate(); debounce?.cancel() }
    func load() {
        let old = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/TartarusControl/profile.json")
        for url in [path,old] {
            guard let data = try? Data(contentsOf:url), let p = try? JSONDecoder().decode(LightProfile.self,from:data), p.valid else { continue }
            red=p.red; green=p.green; blue=p.blue; effect=p.effect; selectedLocation=p.location ?? 0
            cycleStops=p.palette.map { CycleStop(rgb:$0) }; cycleSeconds=p.duration; customCycle=p.customCycle ?? false; break
        }
    }
    // SwiftUI/AppKit can retain a ColorPicker binding after its row is removed.
    // Resolve a stable identity on every callback; a removed identity is inert.
    func cycleColor(id:UUID,fallback:RGB) -> RGB { cycleStops.first { $0.id == id }?.rgb ?? fallback }
    func setCycleColor(id:UUID,rgb:RGB) {
        guard rgb.valid, let index = cycleStops.firstIndex(where:{ $0.id == id }) else { return }
        cycleStops[index].rgb = rgb
    }
    func addCycleColor() {
        guard cycleStops.count < 8 else { return }
        cycleStops.append(CycleStop(rgb:RGB.defaults[cycleStops.count % RGB.defaults.count]))
    }
    func removeCycleColor(id:UUID) {
        guard cycleStops.count > 2, let index = cycleStops.firstIndex(where:{ $0.id == id }) else { return }
        cycleStops.remove(at:index)
    }
    func moveCycleColorEarlier(id:UUID) {
        guard let index = cycleStops.firstIndex(where:{ $0.id == id }), index > 0 else { return }
        cycleStops.swapAt(index,index-1)
    }
    @discardableResult private func save(_ p: LightProfile) -> Bool {
        do {
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(p).write(to:path,options:.atomic)
            return true
        } catch { status = "自动保存失败："+error.localizedDescription; return false }
    }
    func detect() {
        let found = Array(Set(LightHardware.devices().map(LightHardware.location))).filter { $0 != 0 }.sorted()
        if locations != found { locations = found }
        if selectedLocation == 0 && found.count == 1 { selectedLocation = found[0] }
    }
    private var observed: LightProfile?
    private func scheduleIfChanged() {
        let p = profile
        guard p != observed else { return }
        guard p.valid else { status = "灯光配置无效，未发送"; return }
        observed = p; generation += 1; cycling = false; sent = nil
        debounce?.cancel()
        preview = p.effect == .off ? RGB(red:0,green:0,blue:0) : (p.effect == .spectrum && customCycle ? p.palette[0] : RGB(red:red,green:green,blue:blue))
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, p.valid, !self.suspended else { return }
            let saved = self.save(p)
            guard self.connected else { self.status = "配置已保存 · 等待选定设备连接"; return }
            self.cycleStart = ProcessInfo.processInfo.systemUptime
            self.cycling = p.effect == .spectrum && p.customCycle == true
            self.send(p.frame(elapsed:0),generation:self.generation,isCycle:self.cycling,saved:saved)
        }
        debounce = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:task)
    }
    private func tick() {
        guard !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= refreshAt {
            refreshAt = now + 2
            let wasConnected = connected; detect()
            if !connected {
                if wasConnected || cycling { generation += 1; sent = nil; cycling = false; status = "设备已断开 · 重连后自动恢复灯光" }
                return
            }
            if !wasConnected { observed = nil; scheduleIfChanged(); return }
        }
        guard cycling, connected, !busy else { return }
        let frame = profile.frame(elapsed:now-cycleStart)
        preview = RGB(red:frame.red,green:frame.green,blue:frame.blue)
        send(frame,generation:generation,isCycle:true,saved:true)
    }
    private func send(_ p: LightProfile,generation token:Int,isCycle:Bool,saved:Bool) {
        guard !busy, !suspended else {
            // An in-flight transfer finishes before the newest settings are sent.
            if !isCycle { observed = nil }
            return
        }
        busy = true
        let location = selectedLocation
        queue.async { [weak self] in
            let result = LightHardware.apply(p,location:location,volatile:isCycle)
            DispatchQueue.main.async {
                guard let self = self else { return }; self.busy = false
                guard token == self.generation, !self.suspended else { self.scheduleIfChanged(); return }
                if result.ok {
                    self.sent = p
                    self.status = isCycle ? "自定义循环运行中 · 自动保存并实时应用" : (saved ? "已自动保存并应用 · "+p.effect.name : result.message)
                } else {
                    self.cycling = false; self.status = result.message + " 修改设置或重连设备后重试。"
                }
                self.scheduleIfChanged()
            }
        }
    }
    func suspend() { suspended = true; generation += 1; cycling = false; debounce?.cancel() }
    func resume() { suspended = false; observed = nil; detect(); scheduleIfChanged() }
}
