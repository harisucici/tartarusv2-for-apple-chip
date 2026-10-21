import Cocoa
import ApplicationServices
import IOKit.hid

struct MappingResumeState {
    enum Reason: Hashable { case sleep, display, session, lock }
    var enabled = false
    var pauses = Set<Reason>()
    var shouldRun: Bool { enabled && pauses.isEmpty }
}
struct MappingProfile: Codable, Equatable {
    var bindings: [KeyBinding]
    var location: UInt32?
}
final class MappingController: ObservableObject {
    @Published var selectedTab = 0
    @Published var bindings: [KeyBinding] = [] { didSet { scheduleAutoSave() } }
    @Published var selectedLocation: UInt32 = 0 { didSet { scheduleAutoSave() } }
    @Published var locations: [UInt32] = []
    @Published var running = false
    @Published var starting = false
    @Published var lastKey = NSLocalizedString("status.waiting_for_key", comment: "")
    @Published var testText = ""
    @Published var status = NSLocalizedString("status.initial_mapping_only", comment: "")
    @Published var permissionStatus = ""
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var appInputAccess = PermissionCheck.unknown
    @Published private(set) var serviceInputAccess = PermissionCheck.unknown
    @Published private(set) var serviceState = InputServiceState.checking
    @Published private(set) var checkingService = false
    @Published var autoStart = false {
        didSet { UserDefaults.standard.set(autoStart,forKey:"autoStartMappingV03") }
    }
    @Published var selectedSource: Int? = nil
    private let engine = MappingEngine()
    private var activeBindings: [KeyBinding]?
    private let privileged = PrivilegedInput()
    private let eventSource = CGEventSource(stateID:.privateState)
    private struct MacroRun {
        var steps: [MacroStep]
        var index = 0
        var due: TimeInterval
        var releasing = false
        var source: String
    }
    private var macroRuns: [MacroRun] = []
    private var macroSources = Set<String>()
    private var timer: Timer?
    private var repeatTimer: Timer?
    var repeatTimerRunning: Bool { repeatTimer != nil }
    // Used by the self-test only. Production always posts the engine's output.
    var onPhysicalLightingKey:((Int)->Void)?
    var eventSink: ((KeyOutput) -> Void)?
    var scheduleTask: (TimeInterval,DispatchWorkItem) -> Void = { delay,task in
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:task)
    }
    private let profileURL: URL
    private var autoSaveEnabled = false
    private var autoSaveTask: DispatchWorkItem?
    private var lastSaved: MappingProfile?
    private var resumeState = MappingResumeState()
    private var retryTask: DispatchWorkItem?
    private var retryCount = 0
    private var recovering = false
    var path: URL { profileURL }
    init(loadProfile: Bool = true, profileURL: URL? = nil, autoSave: Bool? = nil) {
        self.profileURL = profileURL ?? URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/TartarusControl/mapping.json")
        if loadProfile {
            autoStart = UserDefaults.standard.bool(forKey:"autoStartMappingV03")
            load(); refresh(); checkPermissions()
        }
        autoSaveEnabled = autoSave ?? loadProfile
    }
    deinit { autoSaveTask?.cancel(); retryTask?.cancel(); timer?.invalidate(); repeatTimer?.invalidate() }
    private func scheduleAutoSave() {
        guard autoSaveEnabled else { return }
        autoSaveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in _ = self?.save() }
        autoSaveTask = task
        scheduleTask(0.4,task)
    }
    func load() {
        let old = path.deletingLastPathComponent().appendingPathComponent("profile.json")
        for url in [path,old] {
            guard let d = try? Data(contentsOf:url), let p = try? JSONDecoder().decode(MappingProfile.self,from:d) else { continue }
            bindings = p.bindings.filter { $0.valid }
            selectedLocation = p.location ?? 0; break
        }
    }
    @discardableResult func save() -> Bool {
        autoSaveTask?.cancel(); autoSaveTask = nil
        guard validate() else { return false }
        let profile = MappingProfile(bindings:bindings,location:selectedLocation)
        do {
            if profile != lastSaved {
                try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONEncoder().encode(profile).write(to:path,options:.atomic)
                lastSaved = profile
            }
            if running {
                // Held keys and in-progress macros retain their original snapshots.
                activeBindings = bindings
                status = String(format:NSLocalizedString("status.mapping_enabled",comment:""),String(format:"%08X",selectedLocation))
            } else if !starting && resumeState.pauses.isEmpty {
                status = NSLocalizedString("mapping.auto_saved",comment:"")
            }
            return true
        } catch { status = NSLocalizedString("status.save_failed", comment: "")+error.localizedDescription; return false }
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
        accessibilityGranted = AXIsProcessTrusted()
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: appInputAccess = .granted
        case kIOHIDAccessTypeDenied: appInputAccess = .denied
        default: appInputAccess = .unknown
        }
        let input = appInputAccess == .granted
        permissionStatus = String(format:NSLocalizedString("status.permission_format", comment: ""),
            (AXIsProcessTrusted() ? NSLocalizedString("status.authorized", comment: "") : NSLocalizedString("status.not_authorized", comment: "")),
            (input ? NSLocalizedString("status.authorized", comment: "") : NSLocalizedString("status.not_authorized", comment: "")))
    }
    func refreshSystemChecks() {
        checkPermissions()
        guard !starting, !checkingService else { return }
        if running {
            serviceState = .ready
            if !privileged.checkAccess() { serviceState = .unavailable; serviceInputAccess = .unknown }
            return
        }
        checkingService = true; serviceState = .checking; serviceInputAccess = .unknown
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result = InputServiceInspection.inspect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingService = false
                if self.running || self.starting { self.refreshSystemChecks(); return }
                self.serviceState = result.state; self.serviceInputAccess = result.access
            }
        }
    }
    func openPermissionSettings(input: Bool) {
        let pane = input ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?"+pane) { NSWorkspace.shared.open(url) }
    }
    func showInputService() { NSWorkspace.shared.selectFile(InputService.appPath,inFileViewerRootedAtPath:"") }
    func installInputService() {
        guard !running, !starting else { return }
        starting = true
        privileged.install { [weak self] error in
            guard let self else { return }
            self.starting = false
            self.status = error ?? NSLocalizedString("settings.service.installed",comment:"")
            self.refreshSystemChecks()
        }
    }
    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        checkPermissions()
        status = NSLocalizedString("status.permissions_granted_note", comment: "")
    }
    func start() {
        resumeState.enabled = true
        retryCount = 0; recovering = false
        beginInput(allowInstallation:true)
    }
    private func beginInput(allowInstallation: Bool) {
        guard resumeState.shouldRun, !running, !starting else { return }
        retryTask?.cancel(); retryTask = nil
        refresh(); checkPermissions()
        guard locations.contains(selectedLocation), selectedLocation != 0 else { status = NSLocalizedString("status.bound_not_connected_select", comment: ""); scheduleReconnect(); return }
        guard validate(), !bindings.isEmpty else { if bindings.isEmpty { status = NSLocalizedString("status.add_binding_first", comment: "") }; return }
        guard AXIsProcessTrusted() else { status = NSLocalizedString("status.missing_accessibility", comment: ""); recovering = false; return }
        guard save() else { return }
        activeBindings = bindings
        starting = true
        status = NSLocalizedString("status.waiting_for_admin", comment: "")
        do {
            try privileged.start(location:selectedLocation,allowInstallation:allowInstallation) { [weak self] line in self?.receive(line) }
        } catch { closeInput(); status = NSLocalizedString("status.start_failed", comment: "")+error.localizedDescription; scheduleReconnect() }
    }
    func receive(_ line: String) {
        if line == "ready" {
            guard starting else { return }
            starting = false; running = true
            refreshSystemChecks()
            recovering = false; retryCount = 0
            status = String(format:NSLocalizedString("status.mapping_enabled", comment: ""), String(format:"%08X",selectedLocation))
            timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                guard let self = self else { return }
                if self.running && !AXIsProcessTrusted() { self.stop(); self.status = NSLocalizedString("status.accessibility_revoked", comment: "") }
                else if !self.privileged.ping() { self.closeInput(); self.status = NSLocalizedString("status.helper_disconnected", comment: ""); self.recovering = true; self.scheduleReconnect() }
            }
        } else if line.hasPrefix("access ") {
            serviceInputAccess = PermissionCheck(line:line)
        } else if line.hasPrefix("key ") {
            let v = line.split(separator:" ")
            guard !starting, running, v.count == 4, UInt64(v[1]) != nil, let usage = Int(v[2]), v[3] == "0" || v[3] == "1" else { return }
            process(usage:usage,down:v[3] == "1",source:String(v[1])+":"+String(usage))
        } else if line.hasPrefix("error ") {
            closeInput(); status = String(line.dropFirst(6))
            scheduleReconnect()
            if line.contains("0xe00002e2") { status += NSLocalizedString("status.input_monitor_hint", comment: "") }
        } else if line == "closed" { closeInput(); status = NSLocalizedString("status.helper_closed", comment: ""); recovering = true; scheduleReconnect() }
    }
    func process(usage: Int,down: Bool,source: String) {
        guard running else { return }
        if down { onPhysicalLightingKey?(usage) }
        if down { lastKey = String(format:NSLocalizedString("status.last_key_format", comment: ""), (keys.first { $0.usage == usage }?.name ?? NSLocalizedString("status.unknown_key", comment: "")), usage) }
        let currentBindings = activeBindings ?? bindings
        if macroSources.contains(source) {
            if !down { macroSources.remove(source) }
            return
        }
        if down, let steps = currentBindings.first(where: { $0.source == usage })?.macro, !steps.isEmpty {
            macroSources.insert(source)
            guard macroRuns.count < 16 else { return }
            macroRuns.append(MacroRun(steps:steps,due:ProcessInfo.processInfo.systemUptime,source:"macro:"+UUID().uuidString))
            advanceMacros(now:ProcessInfo.processInfo.systemUptime)
            return
        }
        for output in engine.key(usage:usage,down:down,source:source,bindings:currentBindings,now:ProcessInfo.processInfo.systemUptime) { post(output) }
        updateRepeatTimer()
    }
    private func updateRepeatTimer() {
        guard running && (engine.hasRepeatableKey || !macroRuns.isEmpty) else {
            repeatTimer?.invalidate(); repeatTimer = nil
            return
        }
        guard repeatTimer == nil else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { [weak self] _ in
            guard let self = self, self.running else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.advanceMacros(now:now)
            if let event = self.engine.repeatEvent(now:now) { self.post(event) }
            self.updateRepeatTimer()
        }
    }
    func advanceMacros(now: TimeInterval) {
        guard running else { return }
        for index in macroRuns.indices {
            guard now >= macroRuns[index].due else { continue }
            let run = macroRuns[index], step = run.steps[run.index]
            for event in engine.key(usage:step.usage,down:!run.releasing,source:run.source,bindings:[step.binding],now:now) { post(event) }
            if run.releasing {
                macroRuns[index].index += 1
                macroRuns[index].releasing = false
                macroRuns[index].due = now + step.delay
            } else {
                macroRuns[index].releasing = true
                macroRuns[index].due = now + 0.03
            }
        }
        macroRuns.removeAll { $0.index >= $0.steps.count }
        updateRepeatTimer()
    }
    private func post(_ output: KeyOutput) {
        if let sink = eventSink { sink(output); return }
        guard let event = CGEvent(keyboardEventSource:eventSource,virtualKey:output.code,keyDown:output.down) else { return }
        event.flags = output.flags
        if output.modifier { event.type = .flagsChanged }
        if output.repeating { event.setIntegerValueField(.keyboardEventAutorepeat,value:1) }
        event.post(tap:.cghidEventTap)
    }
    func uninstallInputService() {
        stop(); starting = true
        privileged.uninstall { [weak self] error in
            self?.starting = false
            self?.status = error ?? NSLocalizedString("service.removed",comment:"")
            self?.refreshSystemChecks()
        }
    }
    func suspend(_ reason: MappingResumeState.Reason) {
        resumeState.enabled = resumeState.enabled || running || starting
        resumeState.pauses.insert(reason)
        retryTask?.cancel(); retryTask = nil
        closeInput()
        if resumeState.enabled { status = NSLocalizedString("mapping.paused",comment:"") }
    }
    func resume(_ reason: MappingResumeState.Reason) {
        guard resumeState.pauses.remove(reason) != nil, resumeState.shouldRun else { return }
        recovering = true; retryCount = 0
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        guard recovering, resumeState.shouldRun, retryCount < 10, retryTask == nil else { return }
        retryCount += 1
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryTask = nil
            // Unlock/wake never triggers an installation or password dialog.
            self.beginInput(allowInstallation:false)
        }
        retryTask = task
        scheduleTask(0.75,task)
    }
    func stop() {
        resumeState.enabled = false; recovering = false
        retryTask?.cancel(); retryTask = nil; retryCount = 0
        closeInput()
    }
    private func closeInput() {
        timer?.invalidate(); timer = nil; repeatTimer?.invalidate(); repeatTimer = nil
        macroRuns.removeAll(); macroSources.removeAll()
        privileged.stop()
        for event in engine.releaseAll() { post(event) }
        activeBindings = nil
        running = false; starting = false
        status = NSLocalizedString("status.stopped_input_restored", comment: "")
    }
}
