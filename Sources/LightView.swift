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
    var body: some View { LightingPage(c:c) }
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
                HStack {
                    Text(NSLocalizedString("cycle.duration_label", comment: "")).font(.caption)
                    Slider(value:$c.cycleSeconds,in:10...60,step:1).accessibilityLabel(NSLocalizedString("cycle.duration_accessibility", comment: ""))
                    Text(String(format:NSLocalizedString("cycle.seconds_format", comment: ""),Int(c.cycleSeconds))).font(.system(.caption,design:.monospaced)).frame(width:44)
                }
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
                Text(NSLocalizedString("cycle.custom_explainer", comment: "")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(NSLocalizedString("cycle.builtin_explainer", comment: "")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// Coordinates verified against OpenRGB RazerDevices.cpp, razer_tartarus_v2_layout.
// UI alias 00 denotes the scroll wheel; the printed keys are 01–20.
enum LightLayout {
    static let rows = [[0,1,2,3,4],[6,7,8,9,10],[12,13,14,15,16],[18,19,20,21,22,23]]
    static let active = Set(rows.flatMap { $0 })
    static func label(_ index:Int) -> String {
        if index == 22 { return NSLocalizedString("matrix.wheel",comment:"") }
        if index == 23 { return "20" }
        return String(format:"%02d",index/6*5+index%6+1)
    }
    static func column(_ col:Int) -> Set<Int> { Set(rows.flatMap { $0 }.filter { $0 % 6 == col }) }
}
struct MatrixLightEditor: View {
    @ObservedObject var c:LightController
    var selection:Set<Int> { c.selectedLights }
    func choose(_ indices:Set<Int>) {
        c.selectedLights = indices
    }
    var selectedColor:Binding<Color> {
        Binding(get:{ c.keyColors[selection.sorted().first ?? 0].color },set:{ value in
            if let rgb = NSColor(value).usingColorSpace(.deviceRGB) {
                c.setKeyColors(indices:selection,rgb:RGB(red:rgb.redComponent,green:rgb.greenComponent,blue:rgb.blueComponent))
            }
        })
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(NSLocalizedString("matrix.hint",comment:"")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing:6) {
                Button(NSLocalizedString("matrix.all",comment:"")) { choose(LightLayout.active) }.frame(width:44)
                ForEach(0..<6) { col in
                    Button(String(format:NSLocalizedString("matrix.column",comment:""),col+1)) { choose(LightLayout.column(col)) }
                        .frame(width:40)
                }
            }
            ForEach(0..<4) { row in
                HStack(spacing:6) {
                    Button(String(format:NSLocalizedString("matrix.row",comment:""),row+1)) { choose(Set(LightLayout.rows[row])) }.frame(width:44)
                    ForEach(LightLayout.rows[row],id:\.self) { index in
                        Button { choose([index]) } label: {
                            Text(LightLayout.label(index)).font(.system(size:index == 22 ? 8 : 11,weight:.semibold,design:.monospaced))
                                .frame(width:40,height:36).foregroundStyle(c.keyColors[index].color)
                                .background(.black.opacity(0.5),in:RoundedRectangle(cornerRadius:5))
                                .overlay(RoundedRectangle(cornerRadius:5).stroke(selection.contains(index) ? Color.white : c.keyColors[index].color,lineWidth:selection.contains(index) ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel(LightLayout.label(index)).accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
                    }
                }
            }
            Text(String(format:NSLocalizedString("matrix.selected",comment:""),selection.count)).font(.caption)
            ColorPicker(NSLocalizedString("matrix.color",comment:""),selection:selectedColor,supportsOpacity:false)
            HStack {
                Button(NSLocalizedString("matrix.black",comment:"")) { selectedColor.wrappedValue = .black }
                Button(NSLocalizedString("solid.white",comment:"")) { selectedColor.wrappedValue = .white }
            }
        }
    }
}
