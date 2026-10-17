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
                PageHeading(eyebrow:NSLocalizedString("lights.eyebrow", comment: ""),title:NSLocalizedString("lights.title", comment: ""),detail:NSLocalizedString("lights.detail", comment: ""))
                HStack(alignment:.top,spacing:20) {
                    VStack(alignment:.leading,spacing:18) {
                        ControlCard(title:NSLocalizedString("device.card_title", comment: ""),caption:c.connected ? NSLocalizedString("device.connected", comment: "") : NSLocalizedString("device.disconnected", comment: "")) {
                            HStack {
                                Picker(NSLocalizedString("device.picker_label", comment: ""),selection:$c.selectedLocation) {
                                    Text(NSLocalizedString("device.choose", comment: "")).tag(UInt32(0))
                                    ForEach(c.locations,id:\.self) { loc in Text(String(format:NSLocalizedString("device.tartarus_v2", comment: ""),String(format:"%08X",loc))).tag(loc) }
                                    if c.selectedLocation != 0 && !c.locations.contains(c.selectedLocation) { Text(NSLocalizedString("device.bound_not_connected", comment: "")).tag(c.selectedLocation) }
                                }.labelsHidden()
                                Button { c.detect() } label: { Image(systemName:"arrow.clockwise") }.help(NSLocalizedString("device.rescan_help", comment: ""))
                            }
                        }
                        ControlCard(title:NSLocalizedString("lights.card_title", comment: ""),caption:NSLocalizedString("lights.auto_apply_caption", comment: "")) {
                            Picker(NSLocalizedString("lights.card_title", comment: ""),selection:$c.effect) { ForEach(LightEffect.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                            if c.effect == .solid { solidEditor }
                            else if c.effect == .spectrum { cycleEditor }
                            else { Text(NSLocalizedString("lights.off_hint", comment: "")).foregroundStyle(.secondary).padding(.vertical,10) }
                        }
                    }
                    VStack(spacing:12) {
                        KeypadPreview(color:c.preview.color)
                        Label(NSLocalizedString("preview.label", comment: ""),systemImage:"sparkle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                StatusStrip(text:c.status,active:c.connected)
                ControlCard(title:NSLocalizedString("startup.card_title", comment: "")) {
                    HStack {
                        Toggle(NSLocalizedString("startup.open_at_login", comment: ""),isOn:Binding(get:{startup.requested},set:{startup.setEnabled($0)}))
                        Spacer(); Button(NSLocalizedString("startup.open_settings", comment: "")) { startup.openSettings() }
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
                ColorPicker(NSLocalizedString("solid.color_picker", comment: ""),selection:solidColor,supportsOpacity:false)
            }
            HStack(spacing:10) {
                ForEach(Array(RGB.defaults.enumerated()),id:\.offset) { _,rgb in
                    Button { c.red=rgb.red; c.green=rgb.green; c.blue=rgb.blue } label: { Circle().fill(rgb.color).frame(width:22,height:22) }.buttonStyle(.plain)
                }
                Button(NSLocalizedString("solid.white", comment: "")) { c.red=1; c.green=1; c.blue=1 }
                Spacer()
                Text(String(format:"#%02X%02X%02X",Int(c.red*255),Int(c.green*255),Int(c.blue*255))).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
            }
        }.padding(.top,4)
    }
    var cycleEditor: some View {
        VStack(alignment:.leading,spacing:16) {
            Picker(NSLocalizedString("cycle.mode_picker", comment: ""),selection:$c.customCycle) {
                Text(NSLocalizedString("cycle.full_spectrum", comment: "")).tag(false); Text(NSLocalizedString("cycle.custom", comment: "")).tag(true)
            }.pickerStyle(.segmented)
            if c.customCycle {
                LinearGradient(colors:c.cycleColors.map(\.color)+(c.cycleColors.first.map { [$0.color] } ?? []),startPoint:.leading,endPoint:.trailing).frame(height:8).clipShape(Capsule())
                ForEach(Array(c.cycleStops.enumerated()),id:\.element.id) { index,stop in
                    HStack {
                        Text(String(format:"%02d",index+1)).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).frame(width:22)
                        ColorPicker(String(format:NSLocalizedString("cycle.color_n", comment: ""),index+1),selection:paletteBinding(stop),supportsOpacity:false)
                        Spacer()
                        Button { c.moveCycleColorEarlier(id:stop.id) } label: { Image(systemName:"arrow.up") }.disabled(index == 0).help(NSLocalizedString("cycle.move_earlier_help", comment: ""))
                        Button { c.removeCycleColor(id:stop.id) } label: { Image(systemName:"minus") }.disabled(c.cycleStops.count <= 2).help(NSLocalizedString("cycle.remove_help", comment: ""))
                    }
                }
                HStack { Button { c.addCycleColor() } label: { Label(NSLocalizedString("cycle.add_color", comment: ""),systemImage:"plus") }.disabled(c.cycleStops.count >= 8); Spacer(); Text(NSLocalizedString("cycle.hint_range", comment: "")).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text(NSLocalizedString("cycle.duration_label", comment: "")).font(.caption)
                    Slider(value:$c.cycleSeconds,in:2...60,step:1).accessibilityLabel(NSLocalizedString("cycle.duration_accessibility", comment: ""))
                    Text(String(format:NSLocalizedString("cycle.seconds_format", comment: ""),Int(c.cycleSeconds))).font(.system(.caption,design:.monospaced)).frame(width:44)
                }
                Text(NSLocalizedString("cycle.custom_explainer", comment: "")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(NSLocalizedString("cycle.builtin_explainer", comment: "")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
