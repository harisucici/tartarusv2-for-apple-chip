import SwiftUI

struct MappingView: View {
    @ObservedObject var m: MappingController
    var busy: Bool { m.running || m.starting }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                PageHeading(eyebrow:"KEY ASSIGNMENTS",title:"一键，更多操作",detail:"为 Tartarus 设置单键或组合键。仅映射选定设备，普通键盘不受影响。")
                ControlCard(title:"目标设备",caption:busy ? "映射运行中" : "准备配置") {
                    HStack {
                        Picker("目标设备",selection:$m.selectedLocation) {
                            Text("请选择设备").tag(UInt32(0))
                            ForEach(m.locations,id:\.self) { loc in Text("Tartarus V2 · USB "+String(format:"%08X",loc)).tag(loc) }
                            if m.selectedLocation != 0 && !m.locations.contains(m.selectedLocation) { Text("绑定设备未连接").tag(m.selectedLocation) }
                        }.labelsHidden()
                        Button("检测设备") { m.refresh() }
                        Button("识别按键") { m.observe() }.help("由 Tartarus Light 输入模式读取，可能要求管理员确认；识别期间暂时接管选定设备。")
                    }.disabled(busy || m.monitoring)
                    Text(m.lastKey).font(.system(.caption,design:.monospaced)).foregroundStyle(RazerTheme.green)
                }
                HStack {
                    Text("映射列表").font(.headline)
                    Text("\(m.bindings.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { addBinding() } label: { Label("添加映射",systemImage:"plus") }.disabled(busy || m.monitoring)
                }
                LazyVStack(spacing:12) {
                    ForEach($m.bindings) { $binding in
                        BindingEditor(binding:$binding,learn:{ m.observe(learning:binding.id) },remove:{ m.bindings.removeAll { $0.id == binding.id } })
                    }
                    if m.bindings.isEmpty {
                        Text("添加映射，例如 1 → ⌘⇧C，或 2 → C + V。").foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(30)
                    }
                }.disabled(busy || m.monitoring)
                HStack {
                    Button("保存映射") { m.save() }.disabled(busy || m.monitoring)
                    Button("授权启用改键") { m.save(); if m.validate() { m.start() } }.buttonStyle(.borderedProminent).disabled(busy || m.monitoring || m.bindings.isEmpty)
                    Button("停止 / 恢复") { m.stop() }.keyboardShortcut(.escape,modifiers:[])
                    if m.starting { ProgressView().controlSize(.small) }
                    Spacer()
                }
                ControlCard(title:"测试区域",caption:"点击后按实体按键") {
                    TextField("在此测试 Tartarus 和普通键盘的输出",text:$m.testText).textFieldStyle(.roundedBorder)
                    Text("组合键会执行对应快捷操作；如 ⌘A 会全选测试文字。").font(.caption).foregroundStyle(.secondary)
                }
                StatusStrip(text:m.status,active:m.running)
                ControlCard(title:"权限与启动") {
                    HStack {
                        Button("授予改键权限") { m.requestPermissions() }.disabled(busy)
                        Text(m.permissionStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("启动后自动尝试启用映射",isOn:$m.autoStart).disabled(busy)
                    Text("辅助功能和输入监控均只需 Tartarus Light；旧 TartarusInput 不再使用。灯光无需这两项权限。").font(.caption).foregroundStyle(RazerTheme.green)
                    Text("启用时可能弹出管理员授权。停止、断开或退出会释放设备；换 USB 插口后需重新选择。").font(.caption).foregroundStyle(.secondary)
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
    var learn: () -> Void
    var remove: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:8) {
                    Text("TARTARUS 来源").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(1).foregroundStyle(.secondary)
                    Picker("来源按键",selection:$binding.source) { ForEach(keys) { Text($0.name).tag($0.usage) } }.labelsHidden().frame(width:145)
                }
                Button("识别来源",action:learn).help("通过 Tartarus Light 输入模式识别，可能要求管理员确认；按下来源键后自动释放设备。").padding(.top,18)
                Image(systemName:"arrow.right").foregroundStyle(RazerTheme.green).padding(.horizontal,4)
                VStack(alignment:.leading,spacing:8) {
                    Text("输出组合").font(.system(size:9,weight:.bold)).foregroundStyle(.secondary)
                    Text(binding.display).font(.system(size:18,weight:.semibold,design:.monospaced)).foregroundStyle(RazerTheme.green)
                }
                Spacer()
                Button(action:remove) { Image(systemName:"trash") }.help("删除映射")
            }
            Rectangle().fill(RazerTheme.border).frame(height:1)
            HStack(spacing:12) {
                Text("修饰键").font(.caption).foregroundStyle(.secondary).frame(width:44,alignment:.leading)
                modifier("⌘ Command",value:$binding.command)
                modifier("⇧ Shift",value:$binding.shift)
                modifier("⌥ Option",value:$binding.option)
                modifier("⌃ Control",value:$binding.control)
                Spacer(minLength:0)
            }
            HStack(alignment:.top,spacing:12) {
                Text("目标键").font(.caption).foregroundStyle(.secondary).frame(width:44,alignment:.leading).padding(.top,5)
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        keyPicker("目标按键",selection:$binding.target)
                        Text("主键").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array((binding.extraTargets ?? []).indices),id:\.self) { index in
                        HStack {
                            Text("+").foregroundStyle(RazerTheme.green).frame(width:12)
                            keyPicker("附加目标键 \(index+1)",selection:Binding(get:{ (binding.extraTargets ?? []).indices.contains(index) ? binding.extraTargets![index] : 4 },set:{ if binding.extraTargets?.indices.contains(index) == true { binding.extraTargets![index] = $0 } }))
                            Button { binding.extraTargets?.remove(at:index) } label: { Image(systemName:"minus") }.help("删除目标键")
                        }
                    }
                    Button("添加同时按下的键") {
                        if let next = keys.first(where:{ !binding.targetUsages.contains($0.usage) }) { binding.extraTargets = (binding.extraTargets ?? []) + [next.usage] }
                    }.disabled(binding.targetUsages.count >= 4)
                }
                Spacer()
                VStack(alignment:.trailing,spacing:8) {
                    Menu("快捷模板") {
                        Button("复制 · ⌘C") { preset(6,command:true) }
                        Button("粘贴 · ⌘V") { preset(25,command:true) }
                        Button("截图 · ⌘⇧4") { preset(33,command:true,shift:true) }
                        Button("普通按键") { binding.command=false; binding.shift=false; binding.option=false; binding.control=false; binding.extraTargets=nil }
                    }.frame(width:145)
                    Text("按住来源时一起按下\n松开来源时一起释放").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
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
