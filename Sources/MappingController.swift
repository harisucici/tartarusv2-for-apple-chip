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
    @Published var lastKey = NSLocalizedString("status.waiting_for_key", comment: "")
    @Published var testText = ""
    @Published var status = NSLocalizedString("status.initial_mapping_only", comment: "")
    @Published var permissionStatus = ""
    @Published var autoStart = false {
        didSet { UserDefaults.standard.set(autoStart,forKey:"autoStartMappingV03") }
    }
    private let engine = MappingEngine()
    private let privileged = PrivilegedInput()
    private let eventSource = CGEventSource(stateID:.privateState)
    private var timer: Timer?
    private var repeatTimer: Timer?
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
            status = NSLocalizedString("status.mapping_saved", comment: "")
            if running {
                // Already running: just update bindings in memory (no admin password needed)
                status = String(format:NSLocalizedString("status.mapping_enabled", comment: ""), String(format:"%08X",selectedLocation))
            } else if validate() {
                // First time: need to start the privileged process (requires admin password)
                start()
            }
        } catch { status = NSLocalizedString("status.save_failed", comment: "")+error.localizedDescription }
    }
    @discardableResult func validate() -> Bool {
        guard Set(bindings.map(\.source)).count == bindings.count else { status = NSLocalizedString("status.duplicate_source", comment: ""); return false }
        guard bindings.allSatisfy({ $0.valid }) else { status = NSLocalizedString("status.invalid_combo", comment: ""); return false }
        return true
    }
    func refresh() {
        locations = Array(Set(LightHardware.devices().map(LightHardware.location))).filter { $0 != 0 }.sorted()
        if selectedLocation == 0 && locations.count == 1 { selectedLocation = locations[0] }
    }
    func checkPermissions() {
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        permissionStatus = String(format:NSLocalizedString("status.permission_format", comment: ""),
            (AXIsProcessTrusted() ? NSLocalizedString("status.authorized", comment: "") : NSLocalizedString("status.not_authorized", comment: "")),
            (input ? NSLocalizedString("status.authorized", comment: "") : NSLocalizedString("status.not_authorized", comment: "")))
    }
    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        checkPermissions()
        status = NSLocalizedString("status.permissions_granted_note", comment: "")
    }
    func start() {
        stop(); refresh(); checkPermissions()
        guard locations.contains(selectedLocation), selectedLocation != 0 else { status = NSLocalizedString("status.bound_not_connected_select", comment: ""); return }
        guard validate(), !bindings.isEmpty else { if bindings.isEmpty { status = NSLocalizedString("status.add_binding_first", comment: "") }; return }
        guard AXIsProcessTrusted() else { status = NSLocalizedString("status.missing_accessibility", comment: ""); return }
        starting = true
        status = NSLocalizedString("status.waiting_for_admin", comment: "")
        do {
            try privileged.start(location:selectedLocation) { [weak self] line in self?.receive(line) }
        } catch { stop(); status = NSLocalizedString("status.start_failed", comment: "")+error.localizedDescription }
    }
    func receive(_ line: String) {
        if line == "ready" {
            guard starting else { return }
            starting = false; running = true
            status = String(format:NSLocalizedString("status.mapping_enabled", comment: ""), String(format:"%08X",selectedLocation))
            timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                guard let self = self else { return }
                if self.running && !AXIsProcessTrusted() { self.stop(); self.status = NSLocalizedString("status.accessibility_revoked", comment: "") }
                else if !self.privileged.ping() { self.stop(); self.status = NSLocalizedString("status.helper_disconnected", comment: "") }
            }
            repeatTimer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in
                guard let self = self, self.running else { return }
                if let event = self.engine.repeatEvent(now:ProcessInfo.processInfo.systemUptime) { self.post(event) }
            }
        } else if line.hasPrefix("key ") {
            let v = line.split(separator:" ")
            guard !starting, running, v.count == 4, UInt64(v[1]) != nil, let usage = Int(v[2]), v[3] == "0" || v[3] == "1" else { return }
            process(usage:usage,down:v[3] == "1",source:String(v[1])+":"+String(usage))
        } else if line.hasPrefix("error ") {
            stop(); status = String(line.dropFirst(6))
            if line.contains("0xe00002e2") { status += NSLocalizedString("status.input_monitor_hint", comment: "") }
        } else if line == "closed" { stop(); status = NSLocalizedString("status.helper_closed", comment: "") }
    }
    func process(usage: Int,down: Bool,source: String) {
        guard running else { return }
        if down { lastKey = String(format:NSLocalizedString("status.last_key_format", comment: ""), (keys.first { $0.usage == usage }?.name ?? NSLocalizedString("status.unknown_key", comment: "")), usage) }
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
        running = false; starting = false
        status = NSLocalizedString("status.stopped_input_restored", comment: "")
    }
}
