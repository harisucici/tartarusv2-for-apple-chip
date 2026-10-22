import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct LightingPage:View {
    @ObservedObject var c:LightController
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("TARTARUS V2").font(.system(size:18,weight:.bold,design:.monospaced))
                Text(lightingText(c.studioOpen ? "studio" : "lighting")).foregroundStyle(RazerTheme.green)
                Spacer()
                Picker("",selection:$c.selectedLocation) {
                    Text(NSLocalizedString("device.choose",comment:"")).tag(UInt32(0))
                    ForEach(c.locations,id:\.self) { Text(String(format:"Tartarus V2 · %08X",$0)).tag($0) }
                    if c.selectedLocation != 0 && !c.locations.contains(c.selectedLocation) { Text(NSLocalizedString("device.bound_not_connected",comment:"")).tag(c.selectedLocation) }
                }.frame(maxWidth:240).labelsHidden()
                Button { c.detect() } label:{Image(systemName:"arrow.clockwise")}.help(lightingText("refresh")).accessibilityLabel(lightingText("refresh"))
            }.padding(20).background(.black.opacity(0.35))
            if c.studioOpen { StudioWorkspaceView(c:c) }
            else { lightingSettings }
            StatusStrip(text:c.status,active:c.connected).padding(12)
        }
        .onAppear { c.setPreviewPageVisible(true) }
        .onDisappear { c.setPreviewPageVisible(false) }
    }
    var lightingSettings:some View {
        ScrollView {
            HStack(alignment:.top,spacing:22) {
                VStack(alignment:.leading,spacing:20) {
                    ControlCard(title:lightingText("brightness")) {
                        Toggle(lightingText("enable"),isOn:$c.options.enabled)
                        HStack { Slider(value:$c.options.brightness,in:0...1,step:0.01); Text("\(Int(c.options.brightness*100))%").monospacedDigit().frame(width:44) }
                    }
                    ControlCard(title:lightingText("switchOff")) {
                        Toggle(lightingText("displayOff"),isOn:$c.options.offWhenDisplayOff)
                        Toggle(lightingText("idleOff"),isOn:$c.options.offWhenIdle)
                        HStack { Slider(value:$c.options.idleMinutes,in:1...60,step:1); Text(String(format:lightingText("minutes"),Int(c.options.idleMinutes))).frame(width:70) }.disabled(!c.options.offWhenIdle)
                    }
                    ControlCard(title:lightingText("effects")) {
                        Picker("",selection:$c.options.advanced) {
                            Text(lightingText("quick")).tag(false)
                            Text(lightingText("advanced")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                        if c.options.advanced {
                            profilePicker
                            Button(lightingText("openStudio")) { c.studioOpen=true }.buttonStyle(.borderedProminent)
                            Text(lightingText("advancedHint")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            EffectCataloguePicker(selection:$c.options.quick.effect)
                            Button(lightingText("cycle")) { c.selectCustomCycle() }
                            EffectProperties(c:c,layerID:nil)
                        }
                    }
                }.frame(maxWidth:500)
                VStack(spacing:16) {
                    KeypadPreview(color:c.preview.color,keyColors:c.previewMatrix).equatable()
                    Text(lightingText("livePreview")).font(.caption).foregroundStyle(.secondary)
                    inputNotice
                }.frame(maxWidth:280)
            }.padding(24)
        }
    }
    var profilePicker:some View {
        Picker(lightingText("profile"),selection:Binding(get:{c.workspace.selected},set:{c.switchPreset($0)})) {
            ForEach(c.workspace.presets) { Text($0.name).tag($0.id) }
        }
    }
    @ViewBuilder var inputNotice:some View {
        if c.needsLightingInput && !c.inputReady {
            VStack(alignment:.leading,spacing:8) {
                Text(lightingText("inputHint")).font(.caption).foregroundStyle(.secondary)
                Button(lightingText("inputEnable")) { c.requestLightingInput() }
            }
        }
    }
}

struct EffectProperties:View {
    @ObservedObject var c:LightController
    var layerID:UUID?
    var layer:StudioLayer? { layerID.flatMap { id in c.draftPreset.layers.first {$0.id == id} } ?? (layerID == nil ? c.options.quick : nil) }
    func edit(_ action:(inout StudioLayer)->Void) {
        if let id=layerID { c.editLayer(id,action) }
        else { var next=c.options.quick; action(&next); if next.valid { c.options.quick=next } }
    }
    func field<T>(_ keyPath:WritableKeyPath<StudioLayer,T>,fallback:T) -> Binding<T> {
        Binding(get:{layer?[keyPath:keyPath] ?? fallback},set:{value in edit {$0[keyPath:keyPath]=value}})
    }
    func color(_ index:Int) -> Binding<Color> {
        Binding(get:{ guard let layer,layer.colors.indices.contains(index) else { return Color.black };return layer.colors[index].color },set:{value in
            guard let rgb=NSColor(value).usingColorSpace(.deviceRGB) else { return }
            edit { if $0.colors.indices.contains(index) { $0.colors[index]=RGB(red:rgb.redComponent,green:rgb.greenComponent,blue:rgb.blueComponent) } }
        })
    }
    var body:some View {
        if let layer {
            VStack(alignment:.leading,spacing:12) {
                if layerID != nil {
                    TextField(lightingText("layerName"),text:field(\.name,fallback:""))
                    EffectCataloguePicker(selection:field(\.effect,fallback:.solid))
                }
                if layer.effect == .spectrum {
                    Toggle(lightingText("customPalette"),isOn:field(\.spectrumPalette,fallback:false))
                }
                if layer.effect.animated && [.spectrum,.breathing].contains(layer.effect) {
                    Toggle(lightingText("hsvBlending"),isOn:field(\.useHSVBlending,fallback:true))
                        .help(lightingText("hsvBlendingHelp"))
                }
                if ![StudioEffect.spectrum,.wave,.wheel,.off].contains(layer.effect) || (layer.effect == .spectrum && layer.spectrumPalette) {
                    if layer.effect != .spectrum { Toggle(lightingText("random"),isOn:field(\.random,fallback:false)).disabled(layer.effect == .fire) }
                    ForEach(Array(layer.colors.enumerated()),id:\.offset) { index,_ in
                        HStack {
                            ColorPicker(String(format:lightingText("colorN"),index+1),selection:color(index),supportsOpacity:false)
                            if layer.colors.count > 1 { Button { edit { if $0.colors.indices.contains(index) && $0.colors.count > 1 { $0.colors.remove(at:index) } } } label:{Image(systemName:"minus.circle")}.help(lightingText("removeColor")).accessibilityLabel(lightingText("removeColor")) }
                        }
                    }.disabled(layer.random)
                    if ([.breathing,.starlight].contains(layer.effect) && layer.colors.count < 2) || (layer.effect == .spectrum && layer.colors.count < 8) {
                        Button(lightingText("addColor")) { edit {$0.colors.append(RGB(red:0,green:0.5,blue:1))} }
                    }
                }
                if layer.effect.animated {
                    parameter("duration",value:field(\.duration,fallback:3),range:0.2...60,suffix:lightingText("seconds"))
                    parameter("speed",value:field(\.speed,fallback:1),range:0.1...5,suffix:"×")
                }
                if layerID == nil && layer.effect.supportsNativePlayback {
                    Button(lightingText("restoreNative")) { edit { $0.restoreNativeParameters() } }
                        .disabled(layer.nativeQuickEffect != nil)
                    Text(lightingText(layer.nativeQuickEffect == nil ? "restoreNativeHint" : "nativeActive"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if layer.effect == .wheel {
                    HStack {
                        Button(lightingText("slow")) { edit {$0.duration=3;$0.speed=1} }
                        Button(lightingText("medium")) { edit {$0.duration=2;$0.speed=1} }
                        Button(lightingText("fast")) { edit {$0.duration=1;$0.speed=1} }
                    }
                }
                if layer.effect == .wave {
                    Picker(lightingText("direction"),selection:field(\.angle,fallback:0)) {
                        Text(lightingText("right")).tag(0.0); Text(lightingText("left")).tag(180.0)
                        if layerID != nil { Text(lightingText("down")).tag(90.0); Text(lightingText("up")).tag(270.0) }
                    }
                }
                if layerID != nil && [.wave,.ripple,.wheel].contains(layer.effect) {
                    if layer.effect != .wheel { parameter("width",value:field(\.width,fallback:1),range:0.2...5,suffix:"") }
                    if layer.effect == .wave || layer.effect == .wheel {
                        parameter("angle",value:field(\.angle,fallback:0),range:0...360,suffix:"°")
                        parameter("centerX",value:field(\.centerX,fallback:2.5),range:0...5,suffix:"")
                        parameter("centerY",value:field(\.centerY,fallback:1.5),range:0...3,suffix:"")
                    }
                }
                if layerID != nil {
                    Divider()
                    parameter("opacity",value:field(\.opacity,fallback:1),range:0...1,suffix:"")
                    Text(lightingText("playback")).font(.caption.bold()).foregroundStyle(.secondary)
                    Toggle(lightingText("startOnKey"),isOn:field(\.startOnKey,fallback:false))
                    parameter("delay",value:field(\.delay,fallback:0),range:0...60,suffix:lightingText("seconds"))
                    Stepper(String(format:lightingText("repeat"),layer.repeatCount),value:field(\.repeatCount,fallback:0),in:0...100)
                    Text(lightingText("repeatHint")).font(.caption2).foregroundStyle(.secondary)
                    Picker(lightingText("group"),selection:field(\.group,fallback:nil)) {
                        Text(lightingText("none")).tag(Optional<UUID>.none)
                        ForEach(c.draftPreset.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if c.needsLightingInput && !c.inputReady {
                    Text(lightingText("inputHint")).font(.caption).foregroundStyle(.secondary)
                    Button(lightingText("inputEnable")) { c.requestLightingInput() }
                }
            }.font(.system(size:12))
        }
    }
    func parameter(_ key:String,value:Binding<Double>,range:ClosedRange<Double>,suffix:String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            HStack { Text(lightingText(key)); Spacer(); Text(String(format:"%.1f",value.wrappedValue)+suffix).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value:value,in:range)
        }
    }
}

struct StudioWorkspaceView:View {
    @ObservedObject var c:LightController
    var body:some View {
        VStack(spacing:0) {
            toolbar
            HStack(alignment:.top,spacing:0) {
                layers.frame(width:190)
                Divider()
                VStack(spacing:0) {
                    selectionToolbar
                    ScrollView([.horizontal,.vertical]) { StudioCanvas(c:c).frame(width:440*c.zoom,height:390*c.zoom).padding(24) }
                    previewToolbar
                }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.black.opacity(0.2))
                Divider()
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        Text(lightingText("properties")).font(.caption.bold()).foregroundStyle(.secondary)
                        if let id=c.selectedLayerID { EffectProperties(c:c,layerID:id) }
                        else { Text(lightingText("addHint")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(16)
                }.frame(width:220)
            }
            HStack {
                Text(c.studioDirty ? lightingText("unsaved") : lightingText("saved")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(lightingText("save")) { c.saveStudio() }.keyboardShortcut("s",modifiers:.command).buttonStyle(.borderedProminent)
            }.padding(12).background(.black.opacity(0.25))
        }
    }
    var toolbar:some View {
        HStack {
            Button { c.studioOpen=false } label:{Label(lightingText("back"),systemImage:"chevron.left")}
            Picker(lightingText("profile"),selection:Binding(get:{c.workspace.selected},set:{c.switchPreset($0)})) {
                ForEach(c.workspace.presets) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(maxWidth:190)
            Menu {
                Button(lightingText("newProfile")) { c.newPreset() }
                Button(lightingText("duplicateProfile")) { c.newPreset(duplicate:true) }
                Button(lightingText("deleteProfile")) { c.deletePreset() }.disabled(c.workspace.presets.count == 1)
                Divider()
                Button(lightingText("import")) { c.importPreset() }
                Button(lightingText("export")) { c.exportPreset() }
            } label:{ Image(systemName:"ellipsis") }
            Spacer()
            Button { c.undoStudio() } label:{Image(systemName:"arrow.uturn.backward")}.disabled(c.undoStack.isEmpty).keyboardShortcut("z",modifiers:.command).help(lightingText("undo"))
            Button { c.redoStudio() } label:{Image(systemName:"arrow.uturn.forward")}.disabled(c.redoStack.isEmpty).keyboardShortcut("z",modifiers:[.command,.shift]).help(lightingText("redo"))
        }.padding(12)
    }
    var layers:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(lightingText("layers")).font(.caption.bold()).foregroundStyle(.secondary)
            TextField(lightingText("profile"),text:Binding(get:{c.draftPreset.name},set:{value in
                guard !value.isEmpty,value.count <= 120 else { return };c.recordStudio();c.draftPreset.name=value
            }))
            ScrollView {
                VStack(spacing:5) {
                    ForEach(c.draftPreset.groups) { group in
                        HStack {
                            Button { c.editGroup(group.id) {$0.enabled.toggle()} } label:{Image(systemName:group.enabled ? "eye" : "eye.slash")}.buttonStyle(.plain)
                            Image(systemName:"folder")
                            TextField(lightingText("group"),text:Binding(get:{c.draftPreset.groups.first {$0.id == group.id}?.name ?? group.name},set:{value in c.editGroup(group.id) {$0.name=value}}))
                        }.font(.caption).contextMenu { Button(lightingText("ungroup")) { c.deleteGroup(group.id) } }
                    }
                    ForEach(c.draftPreset.layers) { layer in
                        HStack(spacing:7) {
                            Button { c.editLayer(layer.id) {$0.enabled.toggle()} } label:{Image(systemName:layer.enabled ? "eye" : "eye.slash")}.buttonStyle(.plain)
                            if layer.group != nil { Image(systemName:"folder").font(.caption2) }
                            Text(layer.name).lineLimit(1)
                            Spacer(minLength:0)
                        }.font(.system(size:12)).padding(9)
                            .background(c.selectedLayerID == layer.id ? RazerTheme.green.opacity(0.14) : Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:5))
                            .contentShape(Rectangle()).onTapGesture { c.selectLayer(layer.id) }
                            .onDrag { c.draggedLayerID=layer.id; return NSItemProvider(object:layer.id.uuidString as NSString) }
                            .onDrop(of:[UTType.text],isTargeted:nil) { _ in
                                guard let id=c.draggedLayerID else { return false };c.moveLayer(id,to:layer.id);c.draggedLayerID=nil;return true
                            }
                    }
                }
            }
            HStack(spacing:12) {
                Button { c.addGroup() } label:{Image(systemName:"folder.badge.plus")}.help(lightingText("addGroup"))
                Button { c.duplicateLayer() } label:{Image(systemName:"doc.on.doc")}.disabled(c.selectedLayer == nil).help(lightingText("duplicate"))
                Button { c.deleteLayer() } label:{Image(systemName:"trash")}.disabled(c.selectedLayer == nil).help(lightingText("delete"))
                Spacer(minLength:0)
            }
            HStack {
                Button { c.nudgeLayer(-1) } label:{Image(systemName:"arrow.up")}.help(lightingText("moveUp")).accessibilityLabel(lightingText("moveUp"))
                Button { c.nudgeLayer(1) } label:{Image(systemName:"arrow.down")}.help(lightingText("moveDown")).accessibilityLabel(lightingText("moveDown"))
            }.disabled(c.selectedLayer == nil)
            Divider()
            Text(lightingText("addEffect")).font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:6) {
                ForEach(StudioEffect.referenceCases) { effect in
                    Button { c.addLayer(effect) } label:{Text(effect.name).font(.system(size:10)).frame(maxWidth:.infinity,minHeight:25)}
                }
            }
            Menu(lightingText("extraEffects")) {
                ForEach(StudioEffect.extraCases) { effect in Button(effect.name) { c.addLayer(effect) } }
            }.font(.caption)
        }.padding(12)
    }
    var selectionToolbar:some View {
        VStack(spacing:8) {
            HStack(spacing:8) {
                tool("select","cursorarrow")
                tool("pen","pencil.tip")
                tool("bucket","paintbrush.fill")
                tool("test","hand.tap")
                Spacer()
                Picker(lightingText("selectionMode"),selection:$c.selectionMode) {
                    Text(lightingText("replace")).tag("replace")
                    Text("+").tag("add").accessibilityLabel(lightingText("addSelection"));Text("−").tag("subtract").accessibilityLabel(lightingText("subtractSelection"))
                }.labelsHidden().frame(maxWidth:135)
            }
            HStack {
                Menu(lightingText("quickSelection")) {
                    Button(lightingText("all")) { c.chooseLights(LightLayout.active) }
                    Button(lightingText("none")) { c.selectedLights=[] }
                    Button(lightingText("invert")) { c.selectedLights=LightLayout.active.subtracting(c.selectedLights) }
                    ForEach(0..<4) { row in Button(String(format:lightingText("row"),row+1)) { c.chooseLights(Set(LightLayout.rows[row])) } }
                    ForEach(0..<6) { col in Button(String(format:lightingText("column"),col+1)) { c.chooseLights(LightLayout.column(col)) } }
                    Button(NSLocalizedString("matrix.wheel",comment:"")) { c.chooseLights([22]) }
                    Button("20") { c.chooseLights([23]) }
                }
                Button(lightingText("applySelection")) { c.applySelection() }.disabled(c.selectedLayer == nil)
                Button(lightingText("erase")) { c.eraseSelection() }.disabled(c.selectedLayer == nil)
            }.font(.system(size:10))
            Text(lightingText(c.studioTool == "test" ? "testHint" : "selectionHint")).font(.caption2).foregroundStyle(.secondary)
        }.padding(10)
    }
    func tool(_ name:String,_ symbol:String) -> some View {
        Button { c.studioTool=name } label:{Image(systemName:symbol).foregroundStyle(c.studioTool == name ? RazerTheme.green : .secondary)}.help(lightingText(name)).keyboardShortcut(KeyEquivalent(name == "select" ? "s" : name == "pen" ? "p" : name == "bucket" ? "b" : "t"),modifiers:.control)
    }
    var previewToolbar:some View {
        VStack(spacing:8) {
            Text(String(format:lightingText("selectionCount"),c.selectedLights.count)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { c.togglePreviewPlayback() } label:{Image(systemName:c.previewPaused ? "play.fill" : "pause.fill")}.help(lightingText("pausePreview"))
                Button { c.restartPreview() } label:{Image(systemName:"backward.end")}.help(lightingText("restart"))
                Picker(lightingText("previewSpeed"),selection:$c.previewSpeed) { Text("0.5×").tag(0.5);Text("1×").tag(1.0);Text("2×").tag(2.0) }.labelsHidden().frame(width:65)
                Spacer()
                Slider(value:$c.zoom,in:0.65...1.8).accessibilityLabel(lightingText("zoom")).frame(maxWidth:100)
                Text("\(Int(c.zoom*100))%").font(.caption).monospacedDigit()
            }
            Text(lightingText("previewHint")).font(.caption2).foregroundStyle(.secondary)
        }.padding(10)
    }
}

struct StudioCanvas:View {
    @ObservedObject var c:LightController
    func rect(_ index:Int) -> CGRect {
        let z=c.zoom
        return CGRect(x:Double(index%6)*64*z+18*z,y:Double(index/6)*64*z+58*z,width:54*z,height:(index == 22 ? 62 : 52)*z)
    }
    func hit(_ point:CGPoint) -> Int? { LightLayout.active.first {rect($0).contains(point)} }
    var body:some View {
        ZStack(alignment:.topLeading) {
            RoundedRectangle(cornerRadius:24*c.zoom).fill(Color.white.opacity(0.025)).frame(width:430*c.zoom,height:380*c.zoom)
            Text("TARTARUS V2").font(.system(size:12*c.zoom,weight:.bold,design:.monospaced)).tracking(3).foregroundStyle(.secondary).offset(x:20*c.zoom,y:22*c.zoom)
            ForEach(LightLayout.active.sorted(),id:\.self) { index in
                let box=rect(index),tint=c.previewMatrix[index].color
                RoundedRectangle(cornerRadius:(index == 22 ? 14 : 7)*c.zoom)
                    .fill(Color.black.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius:7*c.zoom).stroke(c.selectedLights.contains(index) ? .white : tint.opacity(0.8),lineWidth:c.selectedLights.contains(index) ? 2 : 1))
                    .overlay(VStack(spacing:3) {
                        if index == 22 { Image(systemName:"computermouse").font(.system(size:15*c.zoom)) }
                        Text(LightLayout.label(index)).font(.system(size:(index == 22 ? 8 : 12)*c.zoom,weight:.medium,design:.monospaced))
                    }.foregroundStyle(tint))
                    .frame(width:box.width,height:box.height).offset(x:box.minX,y:box.minY)
                    .accessibilityElement(children:.ignore).accessibilityLabel(LightLayout.label(index))
                    .accessibilityAddTraits(.isButton).accessibilityAction { c.chooseLights([index]) }
            }
            if let box=c.selectionRectangle {
                Rectangle().fill(RazerTheme.green.opacity(0.1)).overlay(Rectangle().stroke(RazerTheme.green,lineWidth:1)).frame(width:box.width,height:box.height).offset(x:box.minX,y:box.minY)
            }
            Text(lightingText("canvasFooter")).font(.system(size:9*c.zoom,design:.monospaced)).foregroundStyle(.secondary).offset(x:24*c.zoom,y:342*c.zoom)
        }
        .drawingGroup()  // Rasterize the static canvas to reduce view updates
        .contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { value in
            if c.dragOrigin == nil {
                c.dragOrigin=value.startLocation;c.dragBaseSelection=c.selectedLights;c.dragSelection=[]
                if c.studioTool == "pen" || c.studioTool == "bucket" { c.recordStudio();c.inLightingGesture=true }
            }
            if c.studioTool == "pen" {
                if let index=hit(value.location),!c.dragSelection.contains(index) { c.dragSelection.insert(index);c.paintLights([index]) }
            } else if c.studioTool == "bucket" {
                if c.dragSelection.isEmpty,let index=hit(value.location) { c.dragSelection.insert(index);c.fillLights(from:index) }
            } else if c.studioTool == "test" {
                if let index=hit(value.location),!c.dragSelection.contains(index) { c.dragSelection.insert(index);c.lightingHit(index) }
            } else {
                let box=CGRect(x:min(value.startLocation.x,value.location.x),y:min(value.startLocation.y,value.location.y),width:abs(value.location.x-value.startLocation.x),height:abs(value.location.y-value.startLocation.y))
                let indices:Set<Int>
                if box.width < 3 && box.height < 3 { indices=hit(value.location).map {[$0]} ?? [] }
                else { indices=Set(LightLayout.active.filter {rect($0).intersects(box)});c.selectionRectangle=box }
                if c.selectionMode == "add" || NSEvent.modifierFlags.contains(.shift) { c.selectedLights=c.dragBaseSelection.union(indices) }
                else if c.selectionMode == "subtract" || NSEvent.modifierFlags.contains(.option) { c.selectedLights=c.dragBaseSelection.subtracting(indices) }
                else { c.selectedLights=indices }
            }
        }.onEnded { _ in c.dragOrigin=nil;c.selectionRectangle=nil;c.inLightingGesture=false })
    }
}

struct EffectCataloguePicker:View {
    @Binding var selection:StudioEffect
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(lightingText("effect")).font(.caption.bold()).foregroundStyle(.secondary)

            // Visual effect grid with thumbnails
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                ForEach(StudioEffect.referenceCases) { effect in
                    EffectThumbnail(effect:effect,selected:selection == effect)
                        .equatable()
                        .onTapGesture { selection = effect }
                }
            }
            .id(selection)

            if !StudioEffect.extraCases.isEmpty {
                Menu(lightingText("extraEffects")) {
                    ForEach(StudioEffect.extraCases) { effect in
                        Button(effect.name) { selection = effect }
                    }
                }
                .font(.caption)
            }

            // Show selected effect name
            HStack {
                Text(selection.name).font(.system(size:11,weight:.medium))
                Spacer()
            }.padding(.top,4)
        }
    }
}

// Visual thumbnail for effect preview
struct EffectThumbnail: View, Equatable {
    let effect: StudioEffect
    let selected: Bool

    static func == (lhs: EffectThumbnail, rhs: EffectThumbnail) -> Bool {
        lhs.effect == rhs.effect && lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(spacing:4) {
            ZStack {
                RoundedRectangle(cornerRadius:6)
                    .fill(Color.black.opacity(0.6))
                    .frame(width:50,height:36)

                EffectPreviewAnimation(effect: effect, phase: 0)
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .overlay(
                RoundedRectangle(cornerRadius:6)
                    .stroke(selected ? RazerTheme.green : .clear, lineWidth: 2)
            )

            Text(effect.name)
                .font(.system(size: 8))
                .foregroundStyle(selected ? RazerTheme.green : .secondary)
                .lineLimit(1)
        }
    }
}

// Animated preview for different effects
struct EffectPreviewAnimation: View {
    let effect: StudioEffect
    let phase: Double

    var body: some View {
        switch effect {
        case .solid:
            Rectangle().fill(Color.red)
        case .spectrum:
            LinearGradient(
                colors:[.red,.orange,.yellow,.green,.blue,.purple],
                startPoint:.leading,endPoint:.trailing
            )
        case .wave:
            WaveShape(phase:phase).stroke(Color.green,lineWidth:2)
        case .breathing:
            Rectangle().fill(Color.blue.opacity(0.5+0.5*sin(phase*2*Double.pi)))
        case .reactive:
            HStack(spacing:2) {
                ForEach(0..<3,id:\.self) { i in
                    Rectangle().fill(Color.cyan.opacity(i == 0 ? 1 : 0.3))
                }
            }
        case .starlight:
            StarlightPreview(phase:phase)
        case .ripple:
            RipplePreview(phase:phase)
        case .wheel:
            Circle().fill(
                AngularGradient(
                    colors:[.red,.yellow,.green,.blue,.purple,.red],
                    center:.center,
                    startAngle:.degrees(phase*360),
                    endAngle:.degrees(phase*360+360)
                )
            )
        case .fire:
            FirePreview(phase:phase)
        case .off:
            Rectangle().fill(Color.black)
        }
    }
}

struct WaveShape: Shape {
    var phase: Double
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x:0,y:rect.midY))
        for x in stride(from:0,through:rect.width,by:1) {
            let relativeX = x / rect.width
            let y = rect.midY + sin((relativeX + phase) * 2 * Double.pi) * rect.height * 0.3
            path.addLine(to: CGPoint(x:x,y:y))
        }
        return path
    }
}

struct StarlightPreview: View {
    let phase: Double
    var body: some View {
        ZStack {
            ForEach(0..<5,id:\.self) { i in
                let offset = Double(i) * 0.2
                let brightness = max(0, sin((phase + offset) * Double.pi))
                Circle()
                    .fill(Color.white)
                    .frame(width:3,height:3)
                    .offset(x:CGFloat(i * 8 - 16),y:CGFloat(sin(Double(i)) * 8))
                    .opacity(brightness)
            }
        }
    }
}

struct RipplePreview: View {
    let phase: Double
    var body: some View {
        ZStack {
            ForEach(0..<3,id:\.self) { i in
                let scale = (phase + Double(i) * 0.33).truncatingRemainder(dividingBy:1)
                Circle()
                    .stroke(Color.cyan.opacity(1 - scale),lineWidth:1)
                    .scaleEffect(scale * 1.5)
            }
        }
    }
}

struct FirePreview: View {
    let phase: Double
    var body: some View {
        LinearGradient(
            colors:[
                Color(red:1,green:0.12,blue:0),
                Color(red:1,green:0.8,blue:0),
                Color(red:1,green:0.12,blue:0).opacity(0.5 + 0.5 * sin(phase * Double.pi * 4))
            ],
            startPoint:.bottom,endPoint:.top
        )
    }
}
