import SwiftUI

struct MappingView: View {
    @ObservedObject var m: MappingController
    var busy: Bool { m.running || m.starting }

    var selectedBindingIndex: Int? {
        guard let s = m.selectedSource else { return nil }
        return m.bindings.firstIndex { $0.source == s }
    }

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

                // Main split: preview on the left, editor on the right
                HStack(alignment:.top,spacing:20) {
                    VStack(spacing:12) {
                        MappingPreview(
                            bindings: m.bindings,
                            selectedSource: $m.selectedSource,
                            onTapEmpty: { usage in addBinding(for: usage) }
                        )
                        Label(NSLocalizedString("preview.label", comment: ""),systemImage:"sparkle").font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment:.leading,spacing:16) {
                        HStack {
                            Text(NSLocalizedString("mapping.selected_title", comment: "")).font(.headline)
                            if selectedBindingIndex != nil {
                                Text(String(format:NSLocalizedString("mapping.list_count", comment: ""), m.bindings.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { addBinding() } label: { Label(NSLocalizedString("mapping.add_button", comment: ""),systemImage:"plus") }.disabled(m.starting)
                        }

                        if let idx = selectedBindingIndex {
                            BindingEditor(
                                binding: $m.bindings[idx],
                                remove: {
                                    let source = m.bindings[idx].source
                                    m.bindings.remove(at: idx)
                                    if m.selectedSource == source { m.selectedSource = nil }
                                }
                            )
                            .transition(.opacity.combined(with:.move(edge:.top)))
                        } else {
                            placeholderPane
                        }
                    }
                    .frame(minWidth: 420, alignment: .leading)
                    .animation(.easeInOut(duration: 0.18), value: selectedBindingIndex)
                }
                .disabled(m.starting)

                HStack {
                    Text(NSLocalizedString("mapping.auto_save_hint",comment:"")).font(.caption).foregroundStyle(.secondary)
                    if !busy {
                        Button(NSLocalizedString("mapping.enable",comment:"")) { m.start() }
                    }
                    Button(NSLocalizedString("mapping.stop_resume_button", comment: "")) { m.stop() }.keyboardShortcut(.escape,modifiers:[])
                    if m.starting { ProgressView().controlSize(.small) }
                    Spacer()
                }

                ControlCard(title:NSLocalizedString("mapping.test_card_title", comment: ""),caption:NSLocalizedString("mapping.test_card_caption", comment: "")) {
                    TextField(NSLocalizedString("mapping.test_placeholder", comment: ""),text:$m.testText).textFieldStyle(.roundedBorder)
                    Text(NSLocalizedString("mapping.test_hint", comment: "")).font(.caption).foregroundStyle(.secondary)
                }

                StatusStrip(text:m.status,active:m.running)

                Button { m.selectedTab = 2 } label: {
                    Label(NSLocalizedString("settings.open",comment:""),systemImage:"gearshape")
                }
            }.padding(28)
        }
        .onAppear { m.refresh(); m.checkPermissions(); m.selectedSource = nil }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in m.checkPermissions() }
    }

    var placeholderPane: some View {
        VStack(alignment:.leading,spacing:10) {
            Image(systemName: m.bindings.isEmpty ? "plus.square.on.square" : "cursorarrow.rays")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(RazerTheme.green.opacity(0.7))
            Text(m.bindings.isEmpty
                 ? NSLocalizedString("mapping.empty_hint", comment: "")
                 : NSLocalizedString("mapping.select_key_hint", comment: ""))
                .font(.system(size: 13, weight: .medium))
            Text(NSLocalizedString("mapping.select_key_subhint", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        .padding(24)
        .background(RazerTheme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RazerTheme.border))
    }

    func addBinding(for usage: Int? = nil) {
        let source: Int
        if let usage {
            source = usage
        } else {
            source = keys.first { key in !m.bindings.contains { $0.source == key.usage } }?.usage ?? 4
        }
        // If there's already a binding for this source, select it instead of duplicating.
        if let existing = m.bindings.first(where: { $0.source == source }) {
            m.selectedSource = existing.source
            return
        }
        m.bindings.append(KeyBinding(source: source, target: source))
        m.selectedSource = source
    }
}

// MARK: - MappingPreview
// A 4x5 grid of the Tartarus V2's 20 physical keys, showing mapping state.
struct MappingPreview: View {
    let bindings: [KeyBinding]
    @Binding var selectedSource: Int?
    var onTapEmpty: (Int) -> Void

    // Actual Tartarus V2 key layout: [name, HID usage]
    // Row 0: 1, 2, 3, 4, 5
    // Row 1: Tab, Q, W, E, R
    // Row 2: Caps, A, S, D, F
    // Row 3: LShift, Z, X, C, Space
    static let keyLayout: [(name: String, usage: Int)] = [
        // Row 0
        ("1", 30), ("2", 31), ("3", 32), ("4", 33), ("5", 34),
        // Row 1
        ("⇥", 43), ("Q", 20), ("W", 26), ("E", 8), ("R", 21),
        // Row 2
        ("⇪", 57), ("A", 4), ("S", 22), ("D", 7), ("F", 9),
        // Row 3
        ("⇧", 225), ("Z", 29), ("X", 27), ("C", 6), ("␣", 44),
        ("⌥", 226), ("↑", 82), ("↓", 81), ("←", 80), ("→", 79)
    ]

    var body: some View {
        VStack(spacing:14) {
            HStack {
                Text("TARTARUS").font(.system(size:10,weight:.bold,design:.monospaced)).tracking(3)
                Spacer()
                Text("V2").foregroundStyle(RazerTheme.green).font(.caption.bold())
            }

            VStack(spacing:6) {
                ForEach(0..<4) { row in
                    HStack(spacing:6) {
                        ForEach(0..<5) { col in
                            let idx = row * 5 + col
                            keyCell(index: idx)
                        }
                    }
                }
            }
            .rotationEffect(.degrees(-6))
            .padding(.vertical, 6)

            HStack(spacing:6) { ForEach(20..<25) { keyCell(index:$0) } }

            // Thumb wheel
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [.white.opacity(0.06), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                .frame(width: 180, height: 50)
                .overlay(Image(systemName: "waveform.path").font(.title2).foregroundStyle(RazerTheme.green.opacity(0.6)))

            HStack(spacing: 8) {
                Circle().fill(RazerTheme.green).frame(width: 6, height: 6)
                    .shadow(color: RazerTheme.green.opacity(0.7), radius: 4)
                Text(String(format: NSLocalizedString("preview.mapped_count_format", comment: ""),
                            mappedCount, Self.keyLayout.count))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 270)
        .background(
            LinearGradient(colors: [RazerTheme.green.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RazerTheme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("preview.accessibility_label", comment: ""))
    }

    var mappedCount: Int {
        let usages = Set(Self.keyLayout.map { $0.usage })
        return bindings.filter { usages.contains($0.source) }.count
    }

    @ViewBuilder
    func keyCell(index: Int) -> some View {
        let key = Self.keyLayout[index]
        let usage = key.usage
        let binding = bindings.first { $0.source == usage }
        let isSelected = selectedSource == usage
        let hasBinding = binding != nil

        Button {
            if hasBinding {
                selectedSource = isSelected ? nil : usage
            } else {
                onTapEmpty(usage)
            }
        } label: {
            VStack(spacing: 1) {
                Text(key.name)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hasBinding ? RazerTheme.green : Color.gray.opacity(0.55))
                if hasBinding {
                    Text(shortDisplay(binding!))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RazerTheme.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 1)
                } else {
                    Text("·").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.gray.opacity(0.35))
                }
            }
            .frame(width: 40, height: 34)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isSelected ? RazerTheme.green
                            : hasBinding ? RazerTheme.green.opacity(0.7)
                            : Color.gray.opacity(0.22),
                        lineWidth: isSelected ? 1.6 : 1
                    )
            )
            .shadow(
                color: hasBinding
                    ? RazerTheme.green.opacity(isSelected ? 0.6 : 0.22)
                    : (isSelected ? RazerTheme.green.opacity(0.3) : .clear),
                radius: isSelected ? 9 : (hasBinding ? 5 : 0)
            )
            .scaleEffect(isSelected ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: hasBinding)
        }
        .buttonStyle(.plain)
        .help(hasBinding
              ? String(format: NSLocalizedString("preview.key_mapped_help", comment: ""), index + 1, binding!.display)
              : String(format: NSLocalizedString("preview.key_unmapped_help", comment: ""), index + 1))
        .accessibilityLabel(Text(hasBinding
                                 ? String(format: NSLocalizedString("preview.key_mapped_access", comment: ""), index + 1, binding!.display)
                                 : String(format: NSLocalizedString("preview.key_unmapped_access", comment: ""), index + 1)))
    }

    func shortDisplay(_ b: KeyBinding) -> String {
        // Reuse the existing display; strip spaces for compactness in the small cell.
        b.display.replacingOccurrences(of: " + ", with: "+")
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
            Toggle(NSLocalizedString("macro.enabled", comment:""),isOn:Binding(get:{binding.isMacro},set:{binding.macro = $0 ? [MacroStep()] : nil}))
            if binding.isMacro { macroEditor } else {
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
            }
        }.padding(18).background(RazerTheme.panel,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(RazerTheme.border))
    }
    var macroEditor: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(NSLocalizedString("macro.hint",comment:"")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array((binding.macro ?? []).enumerated()),id:\.element.id) { index, step in
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text("\(index+1).")
                        keyPicker("Key",selection:macroBinding(step.id,\.usage,fallback:4))
                        Button { if let i = binding.macro?.firstIndex(where:{$0.id == step.id}), i > 0 { binding.macro?.swapAt(i,i-1) } } label:{ Image(systemName:"arrow.up") }.disabled(index == 0)
                        Button { binding.macro?.removeAll { $0.id == step.id } } label:{ Image(systemName:"minus") }.disabled((binding.macro?.count ?? 0) <= 1)
                    }
                    HStack {
                        modifier("⌘",value:macroBinding(step.id,\.command,fallback:false))
                        modifier("⇧",value:macroBinding(step.id,\.shift,fallback:false))
                        modifier("⌥",value:macroBinding(step.id,\.option,fallback:false))
                        modifier("⌃",value:macroBinding(step.id,\.control,fallback:false))
                        Text(NSLocalizedString("macro.delay",comment:""))
                        TextField("s",value:macroBinding(step.id,\.delay,fallback:0.1),format:.number).frame(width:60)
                        Text("s")
                    }
                }
            }
            Button(NSLocalizedString("macro.add",comment:"")) { binding.macro?.append(MacroStep()) }.disabled((binding.macro?.count ?? 0) >= 100)
        }
    }
    func macroBinding<T>(_ id:UUID,_ keyPath:WritableKeyPath<MacroStep,T>,fallback:T) -> Binding<T> {
        Binding(get:{binding.macro?.first(where:{$0.id == id})?[keyPath:keyPath] ?? fallback},set:{value in
            if let i = binding.macro?.firstIndex(where:{$0.id == id}) { binding.macro?[i][keyPath:keyPath] = value }
        })
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
