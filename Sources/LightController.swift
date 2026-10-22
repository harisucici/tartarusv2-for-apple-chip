import Cocoa
import SwiftUI
import Combine
import IOKit.hid

struct CycleStop: Identifiable {
    let id = UUID()
    var rgb: RGB
}

final class LightController: ObservableObject {
    @Published var options=LightingOptions()
    @Published var workspace=LightingWorkspace.initial(Array(repeating:RGB.defaults[0],count:24))
    @Published var draftPreset=StudioPreset()
    @Published var selectedLayerID:UUID? = nil
    @Published var studioOpen=false
    @Published var studioTool="select"
    @Published var selectionMode="replace"
    @Published var zoom=1.0
    @Published var previewPaused=false
    @Published var previewSpeed=1.0
    var previewTime=0.0
    @Published var previewMatrix=Array(repeating:StudioRenderer.black,count:24)
    @Published var inputReady=false
    @Published var undoStack:[StudioPreset]=[]
    @Published var redoStack:[StudioPreset]=[]
    @Published var selectionRectangle:CGRect? = nil
    var draggedLayerID:UUID? = nil
    var inLightingGesture=false
    var dragOrigin:CGPoint? = nil
    var dragSelection:Set<Int>=[]
    var dragBaseSelection:Set<Int>=[]
    var lightingHits:[LightingHit]=[]
    var previewHits:[LightingHit]=[]
    let lightingInput=LightingInput()
    @Published var displayOff=false { didSet { tick(forceFrame:true) } }
    var idleSeconds:() -> Double = { 0 }  // overridden by self-test; default uses IOKit with 1s cache
    private func _defaultIdleSeconds() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastIdleCheck < 1.0 { return cachedIdleSeconds }
        let service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOHIDSystem"))
        guard service != 0 else {
            lastIdleCheck = now; cachedIdleSeconds = 0; return 0
        }
        defer { IOObjectRelease(service) }
        guard let value=IORegistryEntryCreateCFProperty(service,"HIDIdleTime" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? NSNumber else {
            lastIdleCheck = now; cachedIdleSeconds = 0; return 0
        }
        let result = value.doubleValue / 1_000_000_000
        lastIdleCheck = now; cachedIdleSeconds = result
        return result
    }
    @Published var red = 0.27
    @Published var green = 1.0
    @Published var blue = 0.0
    @Published var effect: LightEffect = .solid
    @Published private(set) var cycleStops = RGB.defaults.map { CycleStop(rgb:$0) }
    var cycleColors: [RGB] { cycleStops.map(\.rgb) }
    @Published var cycleSeconds = 10.0
    @Published var selectedLights:Set<Int> = [0]
    @Published var keyColors = Array(repeating:RGB.defaults[0],count:24)
    @Published var customCycle = false
    @Published var locations: [UInt32] = []
    @Published var selectedLocation: UInt32 = 0
    private(set) var busy = false
    @Published var status = NSLocalizedString("status.waiting_for_device", comment: "")
    @Published private(set) var preview = RGB.defaults[0]
    private var changes: AnyCancellable?
    private var ticker: Timer?
    private var tickInterval: TimeInterval = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastPreviewFrameAt: TimeInterval = 0
    private var previewAnimationUntil: TimeInterval = 0
    private var previewPageVisible = false
    private var publishingPreview = false
    private var previewOptions: LightingOptions?
    private var previewPreset: StudioPreset?
    private var previewDisplayOff: Bool?
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label:"local.tartarus.lighting",qos:.utility)
    private var generation = 0
    var cycleStart: TimeInterval = 0
    private var cycling = false
    private var inputAnimationUntil: TimeInterval = 0
    private var refreshAt: TimeInterval = 0
    private var sent: LightProfile?
    private var suspended = false
    private var inputRequested=false
    private var persistenceError:String?
    private let profileURL:URL?
    private var lastIdleCheck: TimeInterval = 0
    private var cachedIdleSeconds: Double = 0
    var profile: LightProfile { LightProfile(red:red,green:green,blue:blue,effect:effect,location:selectedLocation,cycleColors:cycleColors,cycleSeconds:cycleSeconds,customCycle:customCycle,keyColors:keyColors,lightingOptions:options,lightingWorkspace:workspace) }
    var connected: Bool { locations.contains(selectedLocation) && selectedLocation != 0 }
    var path: URL { profileURL ?? URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/TartarusLight/lights.json") }
    init(loadProfile: Bool = true,profileURL:URL? = nil) {
        self.profileURL=profileURL
        idleSeconds = { [weak self] in self?._defaultIdleSeconds() ?? 0 }
        draftPreset=workspace.preset; selectedLayerID=draftPreset.layers.first?.id
        lightingInput.onHit = { [weak self] in self?.lightingHit($0) }
        guard loadProfile else { return }
        load(); detect()
        // Throttled hardware updates - prevents spamming the device
        changes = objectWillChange
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                guard self?.publishingPreview != true else { return }
                // Published sends before mutation; compare the complete profile on the next turn.
                DispatchQueue.main.async { self?.scheduleIfChanged() }
            }
        configureTicker()
        scheduleIfChanged()
    }
    deinit { ticker?.invalidate(); debounce?.cancel() }
    func load() {
        let old = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support/TartarusControl/profile.json")
        for url in [path,old] {
            guard let data = try? Data(contentsOf:url), let p = try? JSONDecoder().decode(LightProfile.self,from:data), p.valid else { continue }
            loadStudio(p)
            keyColors=p.matrix
            red=p.red; green=p.green; blue=p.blue; effect=p.effect; selectedLocation=p.location ?? 0
            cycleStops=p.palette.map { CycleStop(rgb:$0) }; cycleSeconds=max(10,p.duration); customCycle=p.customCycle ?? false; break
        }
    }
    // SwiftUI/AppKit can retain a ColorPicker binding after its row is removed.
    // Resolve a stable identity on every callback; a removed identity is inert.
    func setKeyColors(indices:Set<Int>, rgb:RGB) {
        guard rgb.valid else { return }
        var next = keyColors
        for index in indices where LightLayout.active.contains(index) { next[index] = rgb }
        keyColors = next
    }
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
    @discardableResult func save(_ p: LightProfile) -> Bool {
        do {
            try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(p).write(to:path,options:.atomic)
            persistenceError=nil
            return true
        } catch { persistenceError=NSLocalizedString("status.auto_save_failed", comment: "")+error.localizedDescription; status=persistenceError!; return false }
    }
    func detect() {
        let found = Array(Set(LightHardware.devices().map(LightHardware.location))).filter { $0 != 0 }.sorted()
        if locations != found { locations = found }
        if selectedLocation == 0 && found.count == 1 { selectedLocation = found[0] }
    }
    private var observed: LightProfile?
    private var hardwareQuickEffect: LightEffect? {
        guard options.enabled, !options.advanced else { return nil }
        return options.quick.nativeQuickEffect
    }
    private var softwareAnimation: Bool {
        let layers = options.advanced ? draftPreset.layers : [options.quick]
        return options.enabled && hardwareQuickEffect == nil && (ProcessInfo.processInfo.systemUptime < inputAnimationUntil || layers.contains { layer in
            layer.enabled && layer.effect.animated && !layer.effect.inputDriven && !layer.startOnKey &&
            (layer.group == nil || !(options.advanced && draftPreset.groups.contains { $0.id == layer.group && !$0.enabled }))
        })
    }
    private var previewVisible: Bool {
        previewPageVisible
    }
    func setPreviewPageVisible(_ visible: Bool) {
        guard previewPageVisible != visible else { return }
        previewPageVisible = visible
        if visible { restartPreviewAnimation() }
        else { configureTicker() }
    }
    private func restartPreviewAnimation() {
        previewAnimationUntil = ProcessInfo.processInfo.systemUptime + 5
        lastPreviewFrameAt = 0
        configureTicker()
        refreshPreview(force:true)
    }
    private func configureTicker() {
        let nativeAnimation = hardwareQuickEffect.map { $0 != .solid && $0 != .off } == true
        let deviceAnimation = softwareAnimation && connected
        let previewAnimation = previewVisible && !previewPaused &&
            ProcessInfo.processInfo.systemUptime < previewAnimationUntil && (softwareAnimation || nativeAnimation)
        // Device frames stay at 10 fps; the visible UI preview needs only 4 fps.
        let interval: TimeInterval = deviceAnimation ? 0.1 : (previewAnimation ? 0.25 : 2)
        guard interval != tickInterval else { return }
        ticker?.invalidate()
        tickInterval = interval
        ticker = Timer(timeInterval:interval,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!,forMode:.common)
    }
    private func refreshPreview(force:Bool=false) {
        let preset = options.advanced ? draftPreset : StudioPreset(layers:[options.quick])
        if !force && previewOptions == options && previewPreset == preset && previewDisplayOff == displayOff { return }
        previewOptions = options; previewPreset = preset; previewDisplayOff = displayOff
        let matrix = renderedFrame(elapsed:previewTime,preview:true).matrix
        publishingPreview = true
        defer { publishingPreview = false }
        if previewMatrix != matrix { previewMatrix = matrix }
        if preview != matrix[0] { preview = matrix[0] }
    }
    private func scheduleIfChanged() {
        configureTicker()
        let p = profile
        if p == observed { return }
        guard p.valid else { status = NSLocalizedString("status.invalid_config", comment: ""); return }
        observed = p; generation += 1; cycling = false; sent = nil
        inputAnimationUntil = 0
        debounce?.cancel()
        cycleStart = ProcessInfo.processInfo.systemUptime
        lastTick = cycleStart
        lightingHits=[];previewHits=[];previewTime=0
        restartPreviewAnimation()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, p.valid, !self.suspended else { return }
            let saved = self.save(p)
            guard self.connected else { self.status = NSLocalizedString("status.config_saved_waiting_device", comment: ""); return }
            self.cycleStart = ProcessInfo.processInfo.systemUptime
            self.cycling = true
            self.send(self.renderedFrame(elapsed:0),generation:self.generation,isCycle:self.cycling,saved:saved)
        }
        debounce = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:task)
    }
    private func tick(forceFrame:Bool=false) {
        guard !suspended else { return }
        configureTicker()
        let now = ProcessInfo.processInfo.systemUptime
        if !previewPaused && now < previewAnimationUntil { previewTime += max(0,now-lastTick)*previewSpeed }
        lastTick = now
        // Show five seconds of UI animation; device animation continues independently.
        if previewVisible && !previewPaused && now < previewAnimationUntil && now - lastPreviewFrameAt >= 0.25 {
            lastPreviewFrameAt = now
            refreshPreview(force:tickInterval < 1 || options.offWhenIdle)
        }
        if now >= refreshAt {
            refreshAt = now + 10
            if needsLightingInput && connected {
                if !inputRequested {
                    inputRequested=true
                    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                }
                lightingInput.start(location:selectedLocation)
            }
            else { lightingInput.stop() }
            inputReady=lightingInput.ready
            let wasConnected = connected; detect()
            if !connected {
                if wasConnected || cycling { generation += 1; sent = nil; cycling = false; status = NSLocalizedString("status.device_disconnected_resume", comment: "") }
                return
            }
            if !wasConnected { observed = nil; scheduleIfChanged(); return }
        }
        guard (cycling || forceFrame), connected, !busy else { return }
        // Static lighting is already stored on the device. Poll only for reconnection.
        guard forceFrame || softwareAnimation || options.offWhenIdle else { return }
        let frame = renderedFrame(elapsed:now-cycleStart)
        guard frame != sent else { return }
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
        // Static/non-animated effects can be stored on device permanently
        let isStaticEffect = [.solid, .spectrum, .wave, .breathing, .reactive, .starlight, .off].contains(p.effect)
        // Native effects can run on the device without continuous frame writes.
        let volatile = !isStaticEffect
        queue.async { [weak self] in
            let result = LightHardware.apply(p,location:location,volatile:volatile)
            DispatchQueue.main.async {
                guard let self = self else { return }; self.busy = false
                guard token == self.generation, !self.suspended else { self.scheduleIfChanged(); return }
                if result.ok {
                    self.sent = p
                    let nextStatus = self.persistenceError ?? lightingText("running")
                    if self.status != nextStatus { self.status = nextStatus }
                    // Keep only the low-frequency device poll for native effects.
                    if isStaticEffect && !self.softwareAnimation && !self.options.offWhenIdle {
                        self.cycling = false
                        self.configureTicker()
                    }
                } else {
                    self.cycling = false; self.status = String(format:NSLocalizedString("status.retry_after_change", comment: ""), result.message)
                }
                self.scheduleIfChanged()
            }
        }
    }
    func suspend(turnOff:Bool=false) {
        if turnOff && options.offWhenDisplayOff && connected {
            var dark=profile; dark.effect = .custom
            dark.keyColors=Array(repeating:StudioRenderer.black,count:24)
            let location=selectedLocation
            // Serialize after any pending frame so it cannot relight the device.
            queue.async { _ = LightHardware.apply(dark,location:location,volatile:true) }
        }
        lightingInput.stop(); suspended = true; generation += 1; cycling = false; debounce?.cancel()
        ticker?.invalidate(); ticker = nil; tickInterval = 0
    }
    func resume() { suspended = false; observed = nil; detect(); scheduleIfChanged() }
}

extension LightController {
    var studioPreset:StudioPreset { draftPreset }
    var selectedLayer:StudioLayer? { draftPreset.layers.first {$0.id == selectedLayerID} }
    var studioDirty:Bool { draftPreset != workspace.preset }
    var needsLightingInput:Bool {
        let layers=options.advanced ? draftPreset.layers : [options.quick]
        return layers.contains {$0.enabled && ($0.effect.inputDriven || $0.startOnKey)}
    }
    func loadStudio(_ p:LightProfile) {
        options=p.lightingOptions ?? LightingOptions()
        workspace=p.lightingWorkspace ?? LightingWorkspace.initial(p.matrix)
        draftPreset=workspace.preset; selectedLayerID=draftPreset.layers.first?.id
        if p.lightingOptions == nil {
            options.enabled=p.effect != .off
            options.advanced=p.effect == .custom
            options.quick.effect=p.effect == .spectrum ? .spectrum : .solid
            // Older profiles used RGB interpolation for their custom palette.
            options.quick.useHSVBlending=false
            options.quick.colors=[RGB(red:p.red,green:p.green,blue:p.blue)]
            options.quick.duration=p.duration
            options.quick.spectrumPalette=p.customCycle == true
            if p.customCycle == true { options.quick.colors=p.palette }
        }
    }
    func recordStudio() {
        undoStack.append(draftPreset)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func editLayer(_ id:UUID,_ action:(inout StudioLayer)->Void) {
        guard let i=draftPreset.layers.firstIndex(where:{$0.id == id}) else { return }
        var next=draftPreset.layers[i]; action(&next)
        guard next.valid, next != draftPreset.layers[i] else { return }
        if !inLightingGesture { recordStudio() }; draftPreset.layers[i]=next
    }
    func selectLayer(_ id:UUID) {
        selectedLayerID=id
        selectedLights=Set(selectedLayer?.mask ?? [])
    }
    func selectCustomCycle() {
        // Expose the reference app's Cycle entry using our existing palette animation.
        var quick=options.quick
        quick.effect = .spectrum;quick.spectrumPalette=true
        if quick.colors.count < 2 { quick.colors=RGB.defaults }
        options.quick=quick
    }
    func addLayer(_ effect:StudioEffect) {
        guard draftPreset.layers.count < 64 else { return }
        recordStudio()
        var layer=StudioLayer(effect:effect,mask:selectedLights.isEmpty ? LightLayout.active : selectedLights)
        layer.group=selectedLayer?.group
        draftPreset.layers.insert(layer,at:0); selectLayer(layer.id)
    }
    func deleteLayer() {
        guard let id=selectedLayerID else { return }
        recordStudio(); draftPreset.layers.removeAll {$0.id == id}; selectedLayerID=draftPreset.layers.first?.id
    }
    func duplicateLayer() {
        guard var layer=selectedLayer, draftPreset.layers.count < 64 else { return }
        recordStudio(); layer.id=UUID(); layer.name += " " + lightingText("copy")
        draftPreset.layers.insert(layer,at:0); selectLayer(layer.id)
    }
    func moveLayer(_ id:UUID,to target:UUID) {
        guard id != target,let from=draftPreset.layers.firstIndex(where:{$0.id == id}),let to=draftPreset.layers.firstIndex(where:{$0.id == target}) else { return }
        recordStudio(); let layer=draftPreset.layers.remove(at:from); draftPreset.layers.insert(layer,at:to)
    }
    func nudgeLayer(_ delta:Int) {
        guard let id=selectedLayerID,let index=draftPreset.layers.firstIndex(where:{$0.id == id}),draftPreset.layers.indices.contains(index+delta) else { return }
        moveLayer(id,to:draftPreset.layers[index+delta].id)
    }
    func addGroup() {
        guard draftPreset.groups.count < 32 else { return }
        recordStudio(); let group=StudioGroup(); draftPreset.groups.append(group)
        if let i=draftPreset.layers.firstIndex(where:{$0.id == selectedLayerID}) { draftPreset.layers[i].group=group.id }
    }
    func editGroup(_ id:UUID,_ action:(inout StudioGroup)->Void) {
        guard let i=draftPreset.groups.firstIndex(where:{$0.id == id}) else { return }
        var next=draftPreset.groups[i]; action(&next)
        guard !next.name.isEmpty,next.name.count <= 120 else { return }
        recordStudio(); draftPreset.groups[i]=next
    }
    func deleteGroup(_ id:UUID) {
        recordStudio(); draftPreset.groups.removeAll {$0.id == id}
        for i in draftPreset.layers.indices where draftPreset.layers[i].group == id { draftPreset.layers[i].group=nil }
    }
    func undoStudio() {
        guard let previous=undoStack.popLast() else { return }
        redoStack.append(draftPreset); draftPreset=previous; reconcileLayer()
    }
    func redoStudio() {
        guard let next=redoStack.popLast() else { return }
        undoStack.append(draftPreset); draftPreset=next; reconcileLayer()
    }
    func reconcileLayer() {
        if !draftPreset.layers.contains(where:{$0.id == selectedLayerID}) { selectedLayerID=draftPreset.layers.first?.id }
    }
    func applySelection() {
        guard let id=selectedLayerID else { return }
        editLayer(id) {$0.mask=selectedLights.sorted()}
    }
    func eraseSelection() {
        guard let id=selectedLayerID else { return }
        editLayer(id) {$0.mask=Set($0.mask).subtracting(selectedLights).sorted()}
    }
    func chooseLights(_ indices:Set<Int>) {
        let indices=indices.intersection(LightLayout.active)
        switch selectionMode {
        case "add": selectedLights.formUnion(indices)
        case "subtract": selectedLights.subtract(indices)
        default:selectedLights=indices
        }
    }
    func paintLights(_ indices:Set<Int>) {
        guard let id=selectedLayerID else { return }
        editLayer(id) {$0.mask=Set($0.mask).union(indices).sorted()}
    }
    func fillLights(from index:Int) {
        let mask=Set(selectedLayer?.mask ?? [])
        let target=mask.contains(index)
        var pending=[index],visited=Set<Int>()
        while let cell=pending.popLast() {
            guard LightLayout.active.contains(cell),!visited.contains(cell),mask.contains(cell) == target else { continue }
            visited.insert(cell)
            for n in [cell-6,cell+6,cell-1,cell+1] where abs(n%6-cell%6)+abs(n/6-cell/6) == 1 { pending.append(n) }
        }
        paintLights(visited)
    }
    @discardableResult func saveStudio() -> Bool {
        guard draftPreset.valid,let i=workspace.presets.firstIndex(where:{$0.id == workspace.selected}) else { return false }
        var next=workspace; next.presets[i]=draftPreset
        var p=profile;p.lightingWorkspace=next
        guard save(p) else { return false }
        workspace=next
        return true
    }
    func switchPreset(_ id:UUID) {
        guard workspace.presets.contains(where:{$0.id == id}) else { return }
        guard saveStudio() else { return } // keep edits when changing profiles
        workspace.selected=id; draftPreset=workspace.preset; reconcileLayer(); undoStack=[]; redoStack=[]
    }
    func newPreset(duplicate:Bool=false) {
        guard workspace.presets.count < 32 else { return }
        guard saveStudio() else { return }; var p=duplicate ? draftPreset : StudioPreset()
        p.id=UUID(); p.name=lightingText("profile")+" \(workspace.presets.count+1)"
        workspace.presets.append(p); workspace.selected=p.id; draftPreset=p; reconcileLayer(); undoStack=[]; redoStack=[]
    }
    func deletePreset() {
        guard workspace.presets.count > 1 else { return }
        workspace.presets.removeAll {$0.id == workspace.selected}; workspace.selected=workspace.presets[0].id
        draftPreset=workspace.preset; reconcileLayer(); undoStack=[]; redoStack=[]
    }
    func importPreset() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            let info=try url.resourceValues(forKeys:[.fileSizeKey])
            guard (info.fileSize ?? 0) <= 1_000_000,workspace.presets.count < 32 else { throw CocoaError(.fileReadTooLarge) }
            var p=try JSONDecoder().decode(StudioPreset.self,from:Data(contentsOf:url))
            guard p.valid else { throw CocoaError(.fileReadCorruptFile) }
            guard saveStudio() else { return }; p.id=UUID(); workspace.presets.append(p); workspace.selected=p.id
            draftPreset=p; reconcileLayer(); undoStack=[]; redoStack=[]
        } catch { status=lightingText("importFailed")+error.localizedDescription }
    }
    func exportPreset() {
        let panel=NSSavePanel(); panel.allowedContentTypes=[.json]; panel.nameFieldStringValue="Chroma-effect.json"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]; try encoder.encode(draftPreset).write(to:url,options:.atomic) }
        catch { status=error.localizedDescription }
    }
    func lightingHit(_ index:Int) {
        guard LightLayout.active.contains(index) else { return }
        let now=ProcessInfo.processInfo.systemUptime
        let time=now-cycleStart
        lightingHits.append(LightingHit(index:index,time:time))
        previewHits.append(LightingHit(index:index,time:previewTime))
        if previewHits.count > 128 { previewHits.removeFirst(previewHits.count-128) }
        if lightingHits.count > 128 { lightingHits.removeFirst(lightingHits.count-128) }
        // Native effects react on the device; they need no software frame per key.
        guard options.enabled && hardwareQuickEffect == nil else { return }
        let layers = options.advanced ? draftPreset.layers : [options.quick]
        for layer in layers where layer.enabled && layer.mask.contains(index) && layer.effect.animated && (layer.effect.inputDriven || layer.startOnKey) {
            if let id=layer.group, options.advanced && draftPreset.groups.contains(where: { $0.id == id && !$0.enabled }) { continue }
            let period=layer.duration/layer.speed
            let lifetime=layer.effect.inputDriven ? period : (layer.repeatCount == 0 ? .infinity : period*Double(layer.repeatCount))
            inputAnimationUntil=max(inputAnimationUntil,now+layer.delay+lifetime+0.2)
        }
        tick(forceFrame:true)
    }
    func requestLightingInput() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        lightingInput.start(location:selectedLocation)
        inputReady=lightingInput.ready
    }
    func restartPreview() { cycleStart=ProcessInfo.processInfo.systemUptime; lightingHits=[]; previewHits=[]; previewPaused=false; previewTime=0; restartPreviewAnimation() }
    func togglePreviewPlayback() {
        previewPaused.toggle()
        if previewPaused { configureTicker() }
        else { restartPreviewAnimation() }
    }
    func renderedFrame(elapsed:Double,preview:Bool=false) -> LightProfile {
        var p=profile
        var preset=options.advanced ? draftPreset : StudioPreset(layers:[options.quick])
        if !options.advanced { preset.layers[0].mask=LightLayout.active.sorted() }
        let idle=options.offWhenIdle ? idleSeconds() : 0
        let dark = !options.enabled || (displayOff && options.offWhenDisplayOff) || (options.offWhenIdle && idle >= options.idleMinutes*60)
        if !preview, !dark, let hardware = hardwareQuickEffect {
            p.effect = hardware
            if hardware == .solid, let color = options.quick.colors.first {
                p.red = color.red; p.green = color.green; p.blue = color.blue
            }
            return p
        }
        p.effect = .custom
        p.keyColors=StudioRenderer.render(preset,time:elapsed,hits:preview ? previewHits : lightingHits,brightness:dark ? 0 : options.brightness)
        return p
    }
}
