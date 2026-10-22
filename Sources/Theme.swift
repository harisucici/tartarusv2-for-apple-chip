import SwiftUI

enum RazerTheme {
    static let green = Color(red:0.27,green:1,blue:0)
    static let background = Color(red:0.045,green:0.05,blue:0.045)
    static let panel = Color(red:0.075,green:0.085,blue:0.075)
    static let border = Color.white.opacity(0.09)
}
struct ControlCard<Content:View>: View {
    var title: String
    var caption: String = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.firstTextBaseline) {
                Text(title).font(.system(size:14,weight:.semibold))
                Spacer()
                if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }.padding(20).background(RazerTheme.panel,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(RazerTheme.border))
    }
}
struct StatusStrip: View {
    var text: String
    var active = true
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            Circle().fill(active ? RazerTheme.green : .gray).frame(width:6,height:6).padding(.top,5)
            Text(text).font(.system(size:12)).textSelection(.enabled)
            Spacer(minLength:0)
        }.padding(14).background(RazerTheme.green.opacity(0.055),in:RoundedRectangle(cornerRadius:8))
    }
}
struct PageHeading: View {
    var eyebrow: String
    var title: String
    var detail: String
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            Text(eyebrow).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(3).foregroundStyle(RazerTheme.green)
            Text(title).font(.system(size:28,weight:.bold))
            Text(detail).font(.system(size:12)).foregroundStyle(.secondary)
        }
    }
}
struct KeypadPreview: View, Equatable {
    var color: Color
    var keyColors:[RGB]? = nil

    static func == (lhs: KeypadPreview, rhs: KeypadPreview) -> Bool {
        lhs.color == rhs.color && lhs.keyColors == rhs.keyColors
    }

    var body: some View {
        VStack(spacing:20) {
            HStack { Text("TARTARUS").font(.system(size:10,weight:.bold,design:.monospaced)).tracking(3); Spacer(); Text("V2").foregroundStyle(RazerTheme.green).font(.caption.bold()) }
            VStack(spacing:7) {
                ForEach(0..<4) { row in
                    HStack(spacing:5) {
                        ForEach(LightLayout.rows[row],id:\.self) { index in
                            let tint = keyColors?[index].color ?? color
                            Text(LightLayout.label(index)).font(.system(size:index == 22 ? 6 : 9,weight:.medium,design:.monospaced))
                                .frame(width:30,height:34).foregroundStyle(tint)
                                .background(Color.black.opacity(0.7),in:RoundedRectangle(cornerRadius:5))
                                .overlay(RoundedRectangle(cornerRadius:5).stroke(tint.opacity(0.65),lineWidth:1))
                        }
                    }
                }
            }.padding(.vertical,8)
            RoundedRectangle(cornerRadius:28).fill(LinearGradient(colors:[.white.opacity(0.06),.black.opacity(0.4)],startPoint:.top,endPoint:.bottom)).frame(width:180,height:60)
                .overlay(Image(systemName:"waveform.path").font(.title2).foregroundStyle(color.opacity(0.8)))
            Text("CHROMA RGB").font(.system(size:9,weight:.medium,design:.monospaced)).tracking(4).foregroundStyle(.secondary)
        }.padding(22).frame(width:250).background(LinearGradient(colors:[color.opacity(0.045),.clear],startPoint:.top,endPoint:.bottom),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(RazerTheme.border))
        .accessibilityElement(children:.ignore).accessibilityLabel(lightingText("previewAccessibility"))
    }
}
