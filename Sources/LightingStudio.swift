import Cocoa
import SwiftUI
import IOKit.hid
import UniformTypeIdentifiers

func lightingText(_ key:String) -> String { NSLocalizedString("studio."+key,comment:"") }

enum StudioEffect:String,Codable,CaseIterable,Identifiable {
    case breathing, fire, reactive, ripple, spectrum, starlight, solid, wave, off, wheel
    // Catalogue mirrors 1kc/razer-macos feature/menu identifiers. Existing effects
    // remain decodable; Fire stays available as an extra rather than being removed.
    static let referenceCases:[StudioEffect] = [.off,.solid,.wave,.spectrum,.reactive,.breathing,.starlight,.ripple,.wheel]
    static let extraCases:[StudioEffect] = [.fire]
    var id:String { rawValue }
    var name:String { lightingText(rawValue) }
    var inputDriven:Bool { self == .reactive || self == .ripple }
    var animated:Bool { self != .solid && self != .off }
}
struct StudioLayer:Codable,Equatable,Identifiable {
    var id = UUID()
    var name:String
    var effect:StudioEffect
    var enabled = true
    var mask:[Int] = LightLayout.active.sorted()
    var colors:[RGB] = [RGB.defaults[0]]
    var random = false
    var spectrumPalette = false
    var duration = 3.0
    var speed = 1.0
    var angle = 0.0
    var width = 1.0
    var centerX = 2.5
    var centerY = 1.5
    var opacity = 1.0
    var startOnKey = false
    var delay = 0.0
    var repeatCount = 0 // zero means indefinitely
    var group:UUID? = nil
    var valid:Bool {
        !name.isEmpty && name.count <= 120 && Set(mask).count == mask.count && Set(mask).isSubset(of:LightLayout.active)
        && (1...8).contains(colors.count) && colors.allSatisfy(\.valid)
        && duration.isFinite && (0.2...60).contains(duration) && speed.isFinite && (0.1...5).contains(speed)
        && angle.isFinite && (0...360).contains(angle) && width.isFinite && (0.2...5).contains(width)
        && centerX.isFinite && (0...5).contains(centerX) && centerY.isFinite && (0...3).contains(centerY)
        && opacity.isFinite && (0...1).contains(opacity) && delay.isFinite && (0...60).contains(delay)
        && (0...100).contains(repeatCount)
    }
    init(effect:StudioEffect,mask:Set<Int> = LightLayout.active) {
        self.effect=effect; self.name=effect.name; self.mask=mask.sorted()
        if effect == .breathing { duration=7 }
        if effect == .wave || effect == .spectrum { colors = RGB.defaults }
        if effect == .fire { colors = [RGB(red:1,green:0.12,blue:0),RGB(red:1,green:0.8,blue:0)] }
    }
}
struct StudioGroup:Codable,Equatable,Identifiable {
    var id = UUID()
    var name = lightingText("group")
    var enabled = true
}
struct StudioPreset:Codable,Equatable,Identifiable {
    var id = UUID()
    var name = lightingText("defaultProfile")
    // Topmost layer wins. Black is opaque; reactive/ripple unlit pixels are transparent.
    var layers:[StudioLayer] = []
    var groups:[StudioGroup] = []
    var valid:Bool {
        !name.isEmpty && name.count <= 120 && layers.count <= 64 && groups.count <= 32
        && Set(layers.map(\.id)).count == layers.count && Set(groups.map(\.id)).count == groups.count
        && groups.allSatisfy { !$0.name.isEmpty && $0.name.count <= 120 }
        && layers.allSatisfy { layer in layer.valid && (layer.group == nil || groups.contains { g in g.id == layer.group }) }
    }
    static func migrated(_ colors:[RGB]) -> StudioPreset {
        var p=StudioPreset()
        // One layer per distinct color preserves existing per-key colors exactly.
        for index in LightLayout.active.sorted() {
            if let i=p.layers.firstIndex(where:{$0.colors[0] == colors[index]}) { p.layers[i].mask.append(index) }
            else { var l=StudioLayer(effect:.solid,mask:[index]); l.colors=[colors[index]]; p.layers.append(l) }
        }
        return p
    }
}
struct LightingWorkspace:Codable,Equatable {
    var version=1
    var presets:[StudioPreset]
    var selected:UUID
    var valid:Bool { version == 1 && (1...32).contains(presets.count) && Set(presets.map(\.id)).count == presets.count && presets.allSatisfy(\.valid) && presets.contains {$0.id == selected} }
    static func initial(_ colors:[RGB]) -> LightingWorkspace { let p=StudioPreset.migrated(colors); return LightingWorkspace(presets:[p],selected:p.id) }
    var preset:StudioPreset { presets.first {$0.id == selected}! }
}
struct LightingOptions:Codable,Equatable {
    var enabled=true
    var brightness=1.0
    var offWhenDisplayOff=true
    var offWhenIdle=false
    var idleMinutes=5.0
    var advanced=false
    var quick=StudioLayer(effect:.solid)
    var valid:Bool { brightness.isFinite && (0...1).contains(brightness) && idleMinutes.isFinite && (1...60).contains(idleMinutes) && quick.valid }
}
struct LightingHit {
    var index:Int
    var time:TimeInterval
}
enum StudioRenderer {
    static let black=RGB(red:0,green:0,blue:0)
    static func mix(_ a:RGB,_ b:RGB,_ t:Double) -> RGB {
        let t=max(0,min(1,t)); return RGB(red:a.red+(b.red-a.red)*t,green:a.green+(b.green-a.green)*t,blue:a.blue+(b.blue-a.blue)*t)
    }
    static func scale(_ c:RGB,_ v:Double) -> RGB { RGB(red:c.red*v,green:c.green*v,blue:c.blue*v) }
    static func rainbow(_ phase:Double) -> RGB {
        let h=phase-floor(phase), x=h*6, f=x-floor(x)
        switch Int(x) {
        case 0:return RGB(red:1,green:f,blue:0)
        case 1:return RGB(red:1-f,green:1,blue:0)
        case 2:return RGB(red:0,green:1,blue:f)
        case 3:return RGB(red:0,green:1-f,blue:1)
        case 4:return RGB(red:f,green:0,blue:1)
        default:return RGB(red:1,green:0,blue:1-f)
        }
    }
    static func noise(_ value:Double) -> Double { let n=sin(value*12.9898+78.233)*43758.5453; return n-floor(n) }
    static func palette(_ colors:[RGB],_ phase:Double) -> RGB {
        guard colors.count > 1 else { return colors[0] }
        let pos=(phase-floor(phase))*Double(colors.count), i=Int(pos)
        return mix(colors[i],colors[(i+1)%colors.count],pos-Double(i))
    }
    static func pixel(_ layer:StudioLayer,index:Int,time:Double,hits:[LightingHit]) -> RGB? {
        var elapsed=time-layer.delay
        if layer.startOnKey {
            guard let hit=hits.last(where:{layer.mask.contains($0.index)}) else { return nil }
            elapsed=time-hit.time-layer.delay
        }
        guard elapsed >= 0 else { return nil }
        let period=layer.duration/layer.speed
        if layer.repeatCount > 0 && elapsed >= period*Double(layer.repeatCount) { return nil }
        let phase=elapsed/period
        let seed=Double(index)*7.31+floor(phase)
        let base=layer.random ? rainbow(noise(floor(phase)+0.3)) : layer.colors[0]
        switch layer.effect {
        case .off:return black
        case .wheel:
            // A new rotating hue field; existing effect branches are unchanged.
            let dx=Double(index%6)-layer.centerX,dy=Double(index/6)-layer.centerY
            let angularPosition=(dx == 0 && dy == 0) ? 0 : atan2(dy,dx)/(2*Double.pi)
            return rainbow(angularPosition-phase+layer.angle/360)
        case .solid:return base
        case .spectrum:return layer.spectrumPalette ? palette(layer.colors,phase) : rainbow(phase)
        case .breathing:
            let amount=(1-cos(phase*2*Double.pi))/2
            if layer.colors.count > 1 && !layer.random { return mix(layer.colors[0],layer.colors[1],amount) }
            return scale(base,amount)
        case .wave:
            let theta=layer.angle*Double.pi/180
            let distance=(Double(index%6)-layer.centerX)*cos(theta)+(Double(index/6)-layer.centerY)*sin(theta)
            return rainbow(phase-distance/(6*layer.width))
        case .fire:
            let tick=elapsed*layer.speed*8, lo=floor(tick)
            let flicker=noise(Double(index)*3.1+lo), next=noise(Double(index)*3.1+lo+1)
            let heat=(flicker+(next-flicker)*(tick-lo))*0.8+Double(index/6)*0.06
            return scale(mix(layer.colors[0],layer.colors.last!,heat),0.35+0.65*heat)
        case .starlight:
            let offset=noise(Double(index))*1.6, p=phase+offset, cycle=floor(p)
            guard noise(Double(index)*9+cycle) > 0.45 else { return black }
            let pulse=pow(max(0,sin((p-cycle)*Double.pi)),2)
            let color=layer.random ? rainbow(noise(seed)) : layer.colors[Int(noise(seed)*Double(layer.colors.count)) % layer.colors.count]
            return scale(color,pulse)
        case .reactive:
            guard let hit=hits.last(where:{$0.index == index}), time >= hit.time, time-hit.time < period else { return nil }
            return scale(base,max(0,1-(time-hit.time)/period))
        case .ripple:
            var amount=0.0
            for hit in hits {
                let age=time-hit.time
                guard age >= 0 && age < period else { continue }
                let dx=Double(index%6-hit.index%6),dy=Double(index/6-hit.index/6)
                let distance=sqrt(dx*dx+dy*dy)
                amount=max(amount,max(0,1-abs(distance-age/period*8)/layer.width)*(1-age/period))
            }
            return amount > 0 ? scale(base,amount) : nil
        }
    }
    static func render(_ preset:StudioPreset,time:Double,hits:[LightingHit],brightness:Double=1) -> [RGB] {
        var matrix=Array(repeating:black,count:24)
        for layer in preset.layers.reversed() where layer.enabled {
            if let id=layer.group, preset.groups.contains(where:{$0.id == id && !$0.enabled}) { continue }
            for index in layer.mask {
                if let color=pixel(layer,index:index,time:time,hits:hits) { matrix[index]=mix(matrix[index],color,layer.opacity) }
            }
        }
        return matrix.map { scale($0,brightness) }
    }
}

// Listen only to the selected physical Tartarus. No keyboard grabs or injection.
final class LightingInput {
    private var manager:IOHIDManager?
    private var pressed=Set<String>()
    var onHit:((Int)->Void)?
    private(set) var location:UInt32=0
    var ready:Bool {
        guard let manager, let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains { device in
            (IOHIDDeviceGetProperty(device,kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue == 1 &&
            (IOHIDDeviceGetProperty(device,kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue == 6
        }
    }
    static let usages=[30,31,32,33,34,43,20,26,8,21,57,4,22,7,9,225,29,27,6,44]
    static func index(page:Int,usage:Int) -> Int? {
        if page == 7, let i=usages.firstIndex(of:usage) { return i == 19 ? 23 : i/5*6+i%5 }
        if page == 9 && usage == 3 { return 22 }
        return nil
    }
    func start(location:UInt32) {
        if location == self.location && ready { return }
        stop()
        guard location != 0, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        let m=IOHIDManagerCreate(kCFAllocatorDefault,0)
        IOHIDManagerSetDeviceMatching(m,LightProtocol.matching(location:location) as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m,{ context,result,_,value in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<LightingInput>.fromOpaque(context).takeUnretainedValue().receive(value)
        },Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m,IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue); return
        }
        manager=m; self.location=location
    }
    private func receive(_ value:IOHIDValue) {
        let element=IOHIDValueGetElement(value)
        let device=IOHIDElementGetDevice(element)
        guard LightHardware.location(device) == location else { return }
        let page=Int(IOHIDElementGetUsagePage(element)), usage=Int(IOHIDElementGetUsage(element))
        let amount=IOHIDValueGetIntegerValue(value)
        if page == 1 && usage == 0x38 && amount != 0 { onHit?(22); return }
        guard let index=Self.index(page:page,usage:usage) else { return }
        let source="\(IOHIDElementGetCookie(element)):\(index)"
        if amount == 0 { pressed.remove(source) }
        else if pressed.insert(source).inserted { onHit?(index) }
    }
    func stop() {
        if let m=manager {
            IOHIDManagerRegisterInputValueCallback(m,nil,nil)
            IOHIDManagerUnscheduleFromRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m,0)
        }
        manager=nil; location=0; pressed.removeAll()
    }
    deinit { stop() }
}
