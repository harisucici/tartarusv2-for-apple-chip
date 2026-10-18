import Foundation
import IOKit.hid
import SwiftUI

func runCoreChecks() {
    runMappingChecks()
    runStudioChecks()
    let p = LightProfile(red:1,green:0,blue:0,effect:.solid,location:17825792)
    let packet = LightProtocol.packet(p)
    precondition(packet.count == 90 && packet[88] == 255)
    precondition(Array(packet.prefix(17)) == [0,31,0,0,0,9,15,2,1,5,1,0,0,1,255,0,0])
    var response = packet; response[0] = 2
    precondition(LightProtocol.acknowledges(response,length:90))
    response[88] ^= 1
    precondition(!LightProtocol.acknowledges(response,length:90))
    response = packet; response[0] = 1
    precondition(!LightProtocol.acknowledges(response,length:90))
    precondition(!LightProtocol.acknowledges([],length:0))
    response = packet; response[0] = 2; response[1] = 0x3f
    precondition(!LightProtocol.acknowledges(response,length:90))
    let loc: UInt32 = 17825792
    precondition(LightProtocol.accepts(vendor:5426,product:555,location:loc,selected:loc))
    precondition(!LightProtocol.accepts(vendor:1133,product:555,location:loc,selected:loc))
    precondition(!LightProtocol.accepts(vendor:5426,product:556,location:loc,selected:loc))
    precondition(!LightProtocol.accepts(vendor:5426,product:555,location:loc+1,selected:loc))
    precondition(!LightProtocol.accepts(vendor:5426,product:555,location:0,selected:0))
    let matching = LightProtocol.matching(location:loc)
    precondition(matching[kIOHIDLocationIDKey] as? UInt32 == loc)
    precondition(matching[kIOHIDVendorIDKey] as? Int == 5426)
    let legacy = Data("{\"red\":0.2,\"green\":0.3,\"blue\":1,\"effect\":3,\"bindings\":[{\"source\":30,\"target\":6}]}".utf8)
    let migrated = try! JSONDecoder().decode(LightProfile.self,from:legacy)
    precondition(migrated.effect == .spectrum && migrated.location == nil && migrated.valid)
    let stored = try! JSONEncoder().encode(p)
    precondition(try! JSONDecoder().decode(LightProfile.self,from:stored).location == loc)
    for mode in [LightEffect.off,.spectrum] {
        var x = p; x.effect = mode
        let data = LightProtocol.packet(x)
        precondition(data[5] == 6 && data[10] == UInt8(mode.rawValue))
    }
    var invalid = p; invalid.red = 1.1
    precondition(!invalid.valid)
    var cycle = p; cycle.effect = .spectrum; cycle.customCycle = true; cycle.cycleSeconds = 4
    cycle.cycleColors = [RGB(red:1,green:0,blue:0),RGB(red:0,green:0,blue:1)]
    var rainbow = cycle; rainbow.customCycle = false; rainbow.cycleSeconds = 10
    precondition(rainbow.frame(elapsed:0) != rainbow.frame(elapsed:5))
    precondition(rainbow.frame(elapsed:0) == rainbow.frame(elapsed:10))
    let halfway = cycle.frame(elapsed:1)
    precondition(halfway.effect == .solid && halfway.red == 0.5 && halfway.blue == 0.5)
    precondition(cycle.frame(elapsed:0) == cycle.frame(elapsed:4))
    precondition(cycle.frame(elapsed:2).blue == 1)
    let transient = LightProtocol.packet(halfway,volatile:true)
    precondition(transient[8] == 0 && transient[10] == 1 && transient[88] == transient[2..<88].reduce(0,^))
    cycle.cycleSeconds = 0; precondition(!cycle.valid)
    cycle.cycleSeconds = 8; cycle.cycleColors = []; precondition(!cycle.valid)
    precondition(migrated.palette == RGB.defaults && migrated.customCycle == nil)
    // Reproduce the crash path with the actual Binding retained by ColorPicker.
    // Removing a row must make its old callbacks inert, not retarget another row.
    let colors = LightController(loadProfile:false)
    let view = ContentView(c:colors,startup:StartupController())
    let removed = colors.cycleStops.last!
    let staleBinding = view.paletteBinding(removed)
    colors.removeCycleColor(id:removed.id)
    let afterRemoval = colors.cycleColors
    _ = staleBinding.wrappedValue
    staleBinding.wrappedValue = .white
    colors.removeCycleColor(id:removed.id); colors.moveCycleColorEarlier(id:removed.id)
    precondition(colors.cycleColors == afterRemoval && colors.cycleStops.count == 2)
    let surviving = colors.cycleStops.last!
    let movedBinding = view.paletteBinding(surviving)
    colors.moveCycleColorEarlier(id:surviving.id)
    movedBinding.wrappedValue = Color(red:1,green:0,blue:0)
    precondition(colors.cycleStops.first?.id == surviving.id)
    precondition(colors.cycleStops.first!.rgb.red > 0.99 && colors.cycleStops.first!.rgb.green < 0.01)
    let minimum = colors.cycleStops.first!
    colors.removeCycleColor(id:minimum.id)
    precondition(colors.cycleStops.count == 2)
    for _ in 0..<500 {
        colors.addCycleColor()
        let stop = colors.cycleStops.last!
        let binding = view.paletteBinding(stop)
        colors.moveCycleColorEarlier(id:stop.id); colors.removeCycleColor(id:stop.id)
        _ = binding.wrappedValue; binding.wrappedValue = .blue
        precondition(colors.cycleStops.count == 2 && colors.profile.valid)
    }
    for _ in 0..<12 { colors.addCycleColor() }
    precondition(colors.cycleStops.count == 8)
    // Matrix layout: 19 main keys, wheel (00), thumb key 20; three holes.
    precondition(LightLayout.active.count == 21 && LightLayout.active.contains(22) && LightLayout.active.contains(23))
    precondition(!LightLayout.active.contains(5) && !LightLayout.active.contains(11) && !LightLayout.active.contains(17))
    colors.effect = .custom
    let blue = RGB(red:0,green:0,blue:1)
    let original = colors.keyColors
    colors.setKeyColors(indices:[22],rgb:blue)
    precondition(colors.keyColors[22] == blue && colors.keyColors[23] == original[23])
    colors.setKeyColors(indices:LightLayout.column(0),rgb:blue)
    precondition([0,6,12,18].allSatisfy { colors.keyColors[$0] == blue })
    precondition(colors.keyColors[1] == original[1])
    colors.setKeyColors(indices:Set(LightLayout.rows[2]),rgb:blue)
    precondition(LightLayout.rows[2].allSatisfy { colors.keyColors[$0] == blue })
    colors.setKeyColors(indices:[-1,5,24],rgb:blue)
    precondition(colors.keyColors[5] == original[5])
    let custom = colors.profile
    precondition(try! JSONDecoder().decode(LightProfile.self,from:JSONEncoder().encode(custom)) == custom)
    let frames = LightProtocol.packets(custom)
    precondition(frames.count == 5)
    for (row, frame) in frames.prefix(4).enumerated() {
        precondition(frame.count == 90 && frame[5] == 0x47 && frame[7] == 3)
        precondition(frame[10] == UInt8(row) && frame[11] == 0 && frame[12] == 5)
        precondition(frame[88] == frame[2..<88].reduce(0,^))
        precondition(frame.withUnsafeBufferPointer { tartarusLightRequestValid($0.baseAddress!) } == 1)
        var ack = frame; ack[0] = 2
        precondition(LightProtocol.acknowledges(ack,length:90,request:frame))
        ack[7] = 2; ack[88] = ack[2..<88].reduce(0,^)
        precondition(!LightProtocol.acknowledges(ack,length:90,request:frame))
    }
    precondition(Array(frames[3][25..<28]) == [0,0,255]) // wheel, not key 20
    precondition(frames[4][5] == 12 && frames[4][10] == 8)
    precondition(frames[4].withUnsafeBufferPointer { tartarusLightRequestValid($0.baseAddress!) } == 1)
    for (offset,value) in [(10,UInt8(4)),(12,UInt8(6)),(7,UInt8(4)),(31,UInt8(1))] {
        var malformed = frames[0]; malformed[offset] = value
        malformed[88] = malformed[2..<88].reduce(0,^)
        precondition(malformed.withUnsafeBufferPointer { tartarusLightRequestValid($0.baseAddress!) } == 0)
    }
    var badMatrix = custom; badMatrix.keyColors = []; precondition(!badMatrix.valid)
    badMatrix.keyColors = Array(repeating:RGB(red:2,green:0,blue:0),count:24); precondition(!badMatrix.valid)
    precondition(migrated.matrix.count == 24 && migrated.matrix[22] == RGB(red:0.2,green:0.3,blue:1))
    print("PASS: matrix layout, wheel isolation, row/column edits, profile migration, packet sequence, native allowlist and command-aware acknowledgements. No device commands.")
    print("PASS: retained ColorPicker binding after deletion, identity after reorder, stale callbacks, 500 edit cycles and palette limits. No device commands.")
    print("PASS: lighting packet vectors, ack validation, physical USB scope, color-only profile migration and round trip. No device commands or startup changes made.")
}
