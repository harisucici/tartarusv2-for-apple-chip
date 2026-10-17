import SwiftUI

struct MappingView: View {
    @ObservedObject var m: MappingController
    var busy: Bool { m.running || m.starting }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                PageHeading(eyebrow:NSLocalizedString("mapping.eyebrow", comment: ""),title:NSLocalizedString("mapping.title", comment: ""),detail:NSLocalizedString("mapping.detail", comment: ""))
                ControlCard(title:NSLocalizedString("mapping.device_card_title", comment: ""),caption:busy ? NSLocalizedString("mapping.device_running", comment: "") : NSLocalizedString("mapping.device_ready", comment: "")) {
                    HStack {
                        Picker(NSLocalizedString("mapping.device_picker_label", comment: ""),selection:$m.selectedLocation) {
                            Text(NSLocalizedString("mapping.device_choose", comment: "")).tag(UInt32(0))
                            ForEach(m.locations,id:\.self) { loc in Text(String(format:NSLocalizedString("mapping.device_tartarus_v2", comment: ""),String(format:"%08X",loc))).tag(loc) }
                            if m.selectedLocation != 0 && !m.locations.contains(m.selectedLocation) { Text(NSLocalizedString("mapping.device_bound_not_connected", comment: "")).tag(m.selectedLocation) }
                        }.labelsHidden()
                        Button(NSLocalizedString("mapping.detect_button", comment: "")) { m.refresh() }
                    }.disabled(busy)
                    Text(m.lastKey).font(.system(.caption,design:.monospaced)).foregroundStyle(RazerTheme.green)
                }
                HStack {
                    Text(NSLocalizedString("mapping.list_title", comment: "")).font(.headline)
                    Text(String(format:NSLocalizedString("mapping.list_count", comment: ""),m.bindings.count)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { addBinding() } label: { Label(NSLocalizedString("mapping.add_button", comment: ""),systemImage:"plus") }.disabled(busy)
                }
                LazyVStack(spacing:12) {
                    ForEach($m.bindings) { $binding in
                        BindingEditor(binding:$binding,remove:{ m.bindings.removeAll { $0.id == binding.id } })
                    }
                    if m.bindings.isEmpty {
                        Text(NSLocalizedString("mapping.empty_hint", comment: "")).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(30)
                    }
                }.disabled(busy)
                HStack {
                    Button(NSLocalizedString("mapping.save_button", comment: "")) { m.save() }.disabled(busy)
                    Button(NSLocalizedString("mapping.stop_resume_button", comment: "")) { m.stop() }.keyboardShortcut(.escape,modifiers:[])
                    if m.starting { ProgressView().controlSize(.small) }
                    Spacer()
                }
                ControlCard(title:NSLocalizedString("mapping.test_card_title", comment: ""),caption:NSLocalizedString("mapping.test_card_caption", comment: "")) {
                    TextField(NSLocalizedString("mapping.test_placeholder", comment: ""),text:$m.testText).textFieldStyle(.roundedBorder)
                    Text(NSLocalizedString("mapping.test_hint", comment: "")).font(.caption).foregroundStyle(.secondary)
                }
                StatusStrip(text:m.status,active:m.running)
                ControlCard(title:NSLocalizedString("mapping.permissions_card_title", comment: "")) {
                    HStack {
                        Button(NSLocalizedString("mapping.permissions_request_button", comment: "")) { m.requestPermissions() }.disabled(busy)
                        Text(m.permissionStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(NSLocalizedString("mapping.auto_start_toggle", comment: ""),isOn:$m.autoStart).disabled(busy)
                    Text(NSLocalizedString("mapping.permissions_hint_primary", comment: "")).font(.caption).foregroundStyle(RazerTheme.green)
                    Text(NSLocalizedString("mapping.permissions_hint_secondary", comment: "")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .onAppear { m.refresh(); m.checkPermissions() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in m.checkPermissions() }
    }
    func addBinding() {
        let source = keys.first { key in !m.bindings.contains { $0.source == key.usage } }?.usage ?? 4
        m.bindings.append(KeyBinding(source:source,target:source))
    }
}
struct BindingEditor: View {
    @Binding var binding: KeyBinding
    var remove: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:8) {
                    Text(NSLocalizedString("editor.tartarus_source_label", comment: "")).font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(.secondary)
                    Picker(NSLocalizedString("editor.source_key_picker", comment: ""),selection:$binding.source) { ForEach(keys) { Text($0.name).tag($0.usage) } }.labelsHidden().frame(width:145)
                }
                Image(systemName:"arrow.right").foregroundStyle(RazerTheme.green).padding(.horizontal,4)
                VStack(alignment:.leading,spacing:8) {
                    Text(NSLocalizedString("editor.output_combo_label", comment: "")).font(.system(size:9,weight:.bold)).foregroundStyle(.secondary)
                    Text(binding.display).font(.system(size:18,weight:.semibold,design:.monospaced)).foregroundStyle(RazerTheme.green)
                }
                Spacer()
                Button(action:remove) { Image(systemName:"trash") }.help(NSLocalizedString("editor.delete_mapping_help", comment: ""))
            }
            Rectangle().fill(RazerTheme.border).frame(height:1)
            HStack(spacing:12) {
                Text(NSLocalizedString("editor.modifiers_label", comment: "")).font(.caption).foregroundStyle(.secondary).frame(width:44,alignment:.leading)
                modifier(NSLocalizedString("editor.modifier.command", comment: ""),value:$binding.command)
                modifier(NSLocalizedString("editor.modifier.shift", comment: ""),value:$binding.shift)
                modifier(NSLocalizedString("editor.modifier.option", comment: ""),value:$binding.option)
                modifier(NSLocalizedString("editor.modifier.control", comment: ""),value:$binding.control)
                Spacer(minLength:0)
            }
            HStack(alignment:.top,spacing:12) {
                Text(NSLocalizedString("editor.target_key_label", comment: "")).font(.caption).foregroundStyle(.secondary).frame(width:44,alignment:.leading).padding(.top,5)
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        keyPicker(NSLocalizedString("editor.target_key_picker", comment: ""),selection:$binding.target)
                        Text(NSLocalizedString("editor.primary_key_label", comment: "")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array((binding.extraTargets ?? []).indices),id:\.self) { index in
                        HStack {
                            Text("+").foregroundStyle(RazerTheme.green).frame(width:12)
                            keyPicker(String(format:NSLocalizedString("editor.extra_target_label", comment: ""),index+1),selection:Binding(get:{ (binding.extraTargets ?? []).indices.contains(index) ? binding.extraTargets![index] : 4 },set:{ if binding.extraTargets?.indices.contains(index) == true { binding.extraTargets![index] = $0 } }))
                            Button { binding.extraTargets?.remove(at:index) } label: { Image(systemName:"minus") }.help(NSLocalizedString("editor.delete_target_key_help", comment: ""))
                        }
                    }
                    Button(NSLocalizedString("editor.add_simultaneous_key", comment: "")) {
                        if let next = keys.first(where:{ !binding.targetUsages.contains($0.usage) }) { binding.extraTargets = (binding.extraTargets ?? []) + [next.usage] }
                    }.disabled(binding.targetUsages.count >= 4)
                }
                Spacer()
                VStack(alignment:.trailing,spacing:8) {
                    Menu(NSLocalizedString("editor.shortcuts_menu", comment: "")) {
                        Button(NSLocalizedString("editor.preset.copy", comment: "")) { preset(6,command:true) }
                        Button(NSLocalizedString("editor.preset.paste", comment: "")) { preset(25,command:true) }
                        Button(NSLocalizedString("editor.preset.screenshot", comment: "")) { preset(33,command:true,shift:true) }
                        Button(NSLocalizedString("editor.preset.plain", comment: "")) { binding.command=false; binding.shift=false; binding.option=false; binding.control=false; binding.extraTargets=nil }
                    }.frame(width:145)
                    Text(NSLocalizedString("editor.hold_release_hint", comment: "")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }.padding(18).background(RazerTheme.panel,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(RazerTheme.border))
    }
    func keyPicker(_ title:String,selection:Binding<Int>) -> some View {
        Picker(title,selection:selection) { ForEach(keys) { Text($0.name).tag($0.usage) } }.labelsHidden().frame(width:155)
    }
    func modifier(_ title:String,value:Binding<Bool>) -> some View {
        Toggle(title,isOn:value).toggleStyle(.button).font(.system(size:11)).help(title)
    }
    func preset(_ usage:Int,command:Bool = false,shift:Bool = false) {
        binding.target=usage; binding.command=command; binding.shift=shift; binding.option=false; binding.control=false; binding.extraTargets=nil
    }
}
