import Cocoa
import SwiftUI

struct ContentView: View {
    @ObservedObject var c: LightController
    @ObservedObject var startup: StartupController
    var solidColor: Binding<Color> {
        Binding(get:{ Color(red:c.red,green:c.green,blue:c.blue) },set:{ color in
            if let rgb = NSColor(color).usingColorSpace(.deviceRGB) { c.red=rgb.redComponent; c.green=rgb.greenComponent; c.blue=rgb.blueComponent }
        })
    }
    func paletteBinding(_ stop:CycleStop) -> Binding<Color> {
        Binding(get:{ c.cycleColor(id:stop.id,fallback:stop.rgb).color },set:{ color in
            if let rgb = NSColor(color).usingColorSpace(.deviceRGB) { c.setCycleColor(id:stop.id,rgb:RGB(red:rgb.redComponent,green:rgb.greenComponent,blue:rgb.blueComponent)) }
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                PageHeading(eyebrow:"CHROMA STUDIO",title:"让色彩随你而动",detail:"调整即生效，设置自动保存。启动和设备重连时自动恢复灯光。")
                HStack(alignment:.top,spacing:20) {
                    VStack(alignment:.leading,spacing:18) {
                        ControlCard(title:"设备",caption:c.connected ? "已连接" : "未连接") {
                            HStack {
                                Picker("目标设备",selection:$c.selectedLocation) {
                                    Text("请选择设备").tag(UInt32(0))
                                    ForEach(c.locations,id:\.self) { loc in Text("Tartarus V2 · "+String(format:"%08X",loc)).tag(loc) }
                                    if c.selectedLocation != 0 && !c.locations.contains(c.selectedLocation) { Text("绑定设备未连接").tag(c.selectedLocation) }
                                }.labelsHidden()
                                Button { c.detect() } label: { Image(systemName:"arrow.clockwise") }.help("重新检测设备")
                            }
                        }
                        ControlCard(title:"灯光效果",caption:"自动应用") {
                            Picker("灯光效果",selection:$c.effect) { ForEach(LightEffect.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                            if c.effect == .solid { solidEditor }
                            else if c.effect == .spectrum { cycleEditor }
                            else { Text("关闭选定设备的背光。").foregroundStyle(.secondary).padding(.vertical,10) }
                        }
                    }
                    VStack(spacing:12) {
                        KeypadPreview(color:c.preview.color)
                        Label("实时预览",systemImage:"sparkle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                StatusStrip(text:c.status,active:c.connected)
                ControlCard(title:"启动设置") {
                    HStack {
                        Toggle("登录后自动打开程序",isOn:Binding(get:{startup.requested},set:{startup.setEnabled($0)}))
                        Spacer(); Button("登录项设置") { startup.openSettings() }
                    }
                    Text(startup.detail).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in startup.refresh() }
    }
    var solidEditor: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                RoundedRectangle(cornerRadius:8).fill(solidColor.wrappedValue).frame(width:52,height:42)
                ColorPicker("背光颜色",selection:solidColor,supportsOpacity:false)
            }
            HStack(spacing:10) {
                ForEach(Array(RGB.defaults.enumerated()),id:\.offset) { _,rgb in
                    Button { c.red=rgb.red; c.green=rgb.green; c.blue=rgb.blue } label: { Circle().fill(rgb.color).frame(width:22,height:22) }.buttonStyle(.plain)
                }
                Button("白色") { c.red=1; c.green=1; c.blue=1 }
                Spacer()
                Text(String(format:"#%02X%02X%02X",Int(c.red*255),Int(c.green*255),Int(c.blue*255))).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
            }
        }.padding(.top,4)
    }
    var cycleEditor: some View {
        VStack(alignment:.leading,spacing:16) {
            Picker("循环模式",selection:$c.customCycle) {
                Text("完整色谱").tag(false); Text("自定义颜色").tag(true)
            }.pickerStyle(.segmented)
            if c.customCycle {
                LinearGradient(colors:c.cycleColors.map(\.color)+(c.cycleColors.first.map { [$0.color] } ?? []),startPoint:.leading,endPoint:.trailing).frame(height:8).clipShape(Capsule())
                ForEach(Array(c.cycleStops.enumerated()),id:\.element.id) { index,stop in
                    HStack {
                        Text(String(format:"%02d",index+1)).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).frame(width:22)
                        ColorPicker("颜色 \(index+1)",selection:paletteBinding(stop),supportsOpacity:false)
                        Spacer()
                        Button { c.moveCycleColorEarlier(id:stop.id) } label: { Image(systemName:"arrow.up") }.disabled(index == 0).help("提前")
                        Button { c.removeCycleColor(id:stop.id) } label: { Image(systemName:"minus") }.disabled(c.cycleStops.count <= 2).help("删除颜色")
                    }
                }
                HStack { Button { c.addCycleColor() } label: { Label("添加颜色",systemImage:"plus") }.disabled(c.cycleStops.count >= 8); Spacer(); Text("2–8 种颜色 · 平滑循环").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text("一轮时长").font(.caption)
                    Slider(value:$c.cycleSeconds,in:2...60,step:1).accessibilityLabel("循环时长")
                    Text("\(Int(c.cycleSeconds)) 秒").font(.system(.caption,design:.monospaced)).frame(width:44)
                }
                Text("自定义循环由程序实时驱动，退出后停留在最后颜色。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("由设备循环完整色谱。选择“自定义颜色”可编辑颜色顺序和速度。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
