import Cocoa
import ApplicationServices
import IOKit.hid

struct MappingProfile: Codable {
    var bindings: [KeyBinding]
    var location: UInt32?
}
final class MappingController: ObservableObject {
    @Published var selectedTab = 0
    @Published var bindings: [KeyBinding] = []
    @Published var selectedLocation: UInt32 = 0
    @Published var locations: [UInt32] = []
    @Published var running = false
    @Published var starting = false
    @Published var monitoring = false
    @Published var lastKey = "等待设备按键"
    @Published var testText = ""
    @Published var status = "仅对选中 USB 位置的 Tartarus V2 改键。"
    @Published var permissionStatus = ""
    @Published var autoStart = false {
        didSet { UserDefaults.standard.set(autoStart,forKey:"autoStartMappingV03") }
    }
    private let engine = MappingEngine()
    private let privileged = PrivilegedInput()
    private let eventSource = CGEventSource(stateID:.privateState)
    private var timer: Timer?
    private var repeatTimer: Timer?
    private var learning: UUID?
    // Used by the self-test only. Production always posts the engine's output.
    var eventSink: ((KeyOutput) -> Void)?
    var path: URL { URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/TartarusControl/mapping.json") }
    init(loadProfile: Bool = true) {
        if loadProfile {
            autoStart = UserDefaults.standard.bool(forKey:"autoStartMappingV03")
            load(); refresh(); checkPermissions()
        }
    }
    func load() {
        let old = path.deletingLastPathComponent().appendingPathComponent("profile.json")
        for url in [path,old] {
            guard let d = try? Data(contentsOf:url), let p = try? JSONDecoder().decode(MappingProfile.self,from:d) else { continue }
            bindings = p.bindings.filter { $0.valid }
            selectedLocation = p.location ?? 0; break
        }
    }
    func save() {
        guard validate() else { return }
        do {
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(MappingProfile(bindings:bindings,location:selectedLocation)).write(to:path,options:.atomic)
            status = "映射和目标 USB 位置已保存；灯光配置单独保存。"
        } catch { status = "保存失败："+error.localizedDescription }
    }
    @discardableResult func validate() -> Bool {
        guard Set(bindings.map(\.source)).count == bindings.count else { status = "同一个来源键只能有一条映射，请删除重复项。"; return false }
        guard bindings.allSatisfy({ $0.valid }) else { status = "每条组合映射需要 1–4 个不同的有效目标键。"; return false }
        return true
    }
    func refresh() {
        locations = Array(Set(LightHardware.devices().map(LightHardware.location))).filter { $0 != 0 }.sorted()
        if selectedLocation == 0 && locations.count == 1 { selectedLocation = locations[0] }
    }
    func checkPermissions() {
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        permissionStatus = "Tartarus Light · 辅助功能："+(AXIsProcessTrusted() ? "已授权" : "未授权")+" · 输入监控："+(input ? "已授权" : "未授权")
    }
    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        checkPermissions()
        status = "辅助功能和输入监控均只需 Tartarus Light。旧的 TartarusInput 不再使用；管理员密码只在系统框内输入。"
    }
    func start() {
        stop(); refresh(); checkPermissions()
        guard locations.contains(selectedLocation), selectedLocation != 0 else { status = "绑定设备未连接，请检测并选择设备。"; return }
        guard validate(), !bindings.isEmpty else { if bindings.isEmpty { status = "请先添加映射。" }; return }
        guard AXIsProcessTrusted() else { status = "缺少辅助功能权限，请先点击授权。"; return }
        starting = true
        status = "等待 macOS 管理员授权，仅接管所选 Tartarus V2。"
        do {
            try privileged.start(location:selectedLocation) { [weak self] line in self?.receive(line) }
        } catch { stop(); status = "启动失败："+error.localizedDescription }
    }
    func receive(_ line: String) {
        if line == "ready" {
            guard starting else { return }
            starting = false; running = !monitoring
            status = monitoring ? (learning == nil ? "正在识别选定 Tartarus；期间暂停其原始输入，按停止可恢复。" : "请按一下来源键；识别后自动释放 Tartarus。") : "映射已启用，仅 USB "+String(format:"%08X",selectedLocation)+"；其他设备不做改键。"
            timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                guard let self = self else { return }
                if self.running && !AXIsProcessTrusted() { self.stop(); self.status = "辅助功能授权已失效，已停止映射。" }
                else if !self.privileged.ping() { self.stop(); self.status = "辅助进程已断开，已停止映射。" }
            }
            repeatTimer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in
                guard let self = self, self.running else { return }
                if let event = self.engine.repeatEvent(now:ProcessInfo.processInfo.systemUptime) { self.post(event) }
            }
        } else if line.hasPrefix("key ") {
            let v = line.split(separator:" ")
            guard !starting, (running || monitoring), v.count == 4, UInt64(v[1]) != nil, let usage = Int(v[2]), v[3] == "0" || v[3] == "1" else { return }
            process(usage:usage,down:v[3] == "1",source:String(v[1])+":"+String(usage))
        } else if line.hasPrefix("error ") {
            stop(); status = String(line.dropFirst(6))
            if line.contains("0xe00002e2") { status += "。输入监控请允许当前的 Tartarus Light；旧 TartarusInput 授权不适用于新版。" }
        } else if line == "closed" { stop(); status = "辅助进程结束，设备输入已恢复。" }
    }
    func process(usage: Int,down: Bool,source: String) {
        if monitoring {
            if down { observedKey(usage) }
            return
        }
        guard running else { return }
        if down { lastKey = (keys.first { $0.usage == usage }?.name ?? "未知键")+" · HID \(usage)" }
        for output in engine.key(usage:usage,down:down,source:source,bindings:bindings,now:ProcessInfo.processInfo.systemUptime) { post(output) }
    }
    private func post(_ output: KeyOutput) {
        if let sink = eventSink { sink(output); return }
        guard let event = CGEvent(keyboardEventSource:eventSource,virtualKey:output.code,keyDown:output.down) else { return }
        event.flags = output.flags
        if output.modifier { event.type = .flagsChanged }
        if output.repeating { event.setIntegerValueField(.keyboardEventAutorepeat,value:1) }
        event.post(tap:.cghidEventTap)
    }
    func stop() {
        timer?.invalidate(); timer = nil; repeatTimer?.invalidate(); repeatTimer = nil
        privileged.stop()
        for event in engine.releaseAll() { post(event) }
        learning = nil
        running = false; starting = false; monitoring = false
        status = "已停止，原始设备输入已恢复。"
    }
    func observe(learning id: UUID? = nil) {
        stop(); refresh()
        guard selectedLocation != 0, locations.contains(selectedLocation) else { status = "请选择已连接设备。"; return }
        learning = id; monitoring = true; starting = true
        status = "由 Tartarus Light 输入模式识别按键，等待管理员授权。"
        do {
            try privileged.start(location:selectedLocation) { [weak self] line in self?.receive(line) }
        } catch { stop(); status = "识别启动失败："+error.localizedDescription }
    }
    private func observedKey(_ usage: Int) {
        guard monitoring, let key = keys.first(where:{$0.usage == usage}) else { return }
        lastKey = key.name+" · HID \(usage)"
        if let id = learning, let index = bindings.firstIndex(where:{$0.id == id}) {
            bindings[index].source = usage
            stop(); status = "已识别来源："+key.name+"；保存后再启用映射。"
        }
    }
}
