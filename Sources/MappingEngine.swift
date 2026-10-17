import Foundation
import ApplicationServices

struct Key: Identifiable {
    let name: String; let usage: Int; let code: UInt16
    var id: Int { usage }
}
let keys: [Key] = {
    let letters: [(String, UInt16)] = [("A",0),("B",11),("C",8),("D",2),("E",14),("F",3),("G",5),("H",4),("I",34),("J",38),("K",40),("L",37),("M",46),("N",45),("O",31),("P",35),("Q",12),("R",15),("S",1),("T",17),("U",32),("V",9),("W",13),("X",7),("Y",16),("Z",6)]
    var result = letters.enumerated().map { Key(name:$0.element.0, usage:$0.offset+4, code:$0.element.1) }
    let nums: [UInt16] = [18,19,20,21,23,22,26,28,25,29]
    result += nums.enumerated().map { Key(name:String(($0.offset+1)%10),usage:30+$0.offset,code:$0.element) }
    let extra: [(String,Int,UInt16)] = [("Return",40,36),("Escape",41,53),("Delete",42,51),("Tab",43,48),("Space",44,49),("-",45,27),("=",46,24),("[",47,33),("]",48,30),("\\",49,42),(";",51,41),("'",52,39),("`",53,50),(",",54,43),(".",55,47),("/",56,44),("Caps Lock",57,57),("Right",79,124),("Left",80,123),("Down",81,125),("Up",82,126),("Left Ctrl",224,59),("Left Shift",225,56),("Left Option",226,58),("Left Command",227,55),("Right Ctrl",228,62),("Right Shift",229,60),("Right Option",230,61),("Right Command",231,54)]
    result += extra.map { Key(name:$0.0,usage:$0.1,code:$0.2) }
    let f: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111]
    result += f.enumerated().map { Key(name:"F\($0.offset+1)",usage:58+$0.offset,code:$0.element) }
    let extraFunctions: [UInt16] = [105,107,113,106,64,79,80,90]
    result += extraFunctions.enumerated().map { Key(name:"F\($0.offset+13)",usage:104+$0.offset,code:$0.element) }
    let navigation: [(String,Int,UInt16)] = [("Home",74,115),("Page Up",75,116),("Forward Delete",76,117),("End",77,119),("Page Down",78,121),("Keypad Clear",83,71),("Keypad /",84,75),("Keypad *",85,67),("Keypad -",86,78),("Keypad +",87,69),("Keypad Enter",88,76),("Keypad 1",89,83),("Keypad 2",90,84),("Keypad 3",91,85),("Keypad 4",92,86),("Keypad 5",93,87),("Keypad 6",94,88),("Keypad 7",95,89),("Keypad 8",96,91),("Keypad 9",97,92),("Keypad 0",98,82),("Keypad .",99,65)]
    result += navigation.map { Key(name:$0.0,usage:$0.1,code:$0.2) }
    return result
}()
struct KeyBinding: Codable, Identifiable {
    var id = UUID(); var source = 4; var target = 4
    var command = false; var shift = false; var option = false; var control = false
    var extraTargets: [Int]? = nil
    var targetUsages: [Int] { [target] + (extraTargets ?? []) }
    var valid: Bool {
        keys.contains { $0.usage == source } && (1...4).contains(targetUsages.count)
        && Set(targetUsages).count == targetUsages.count
        && targetUsages.allSatisfy { usage in keys.contains { $0.usage == usage } }
    }
    var display: String {
        let mods = [control ? "⌃" : "", option ? "⌥" : "", shift ? "⇧" : "", command ? "⌘" : ""].joined()
        return mods + targetUsages.compactMap { usage in keys.first { $0.usage == usage }?.name }.joined(separator:" + ")
    }
    var flags: CGEventFlags {
        var f: CGEventFlags = []
        if command { f.insert(.maskCommand) }; if shift { f.insert(.maskShift) }
        if option { f.insert(.maskAlternate) }; if control { f.insert(.maskControl) }; return f
    }
}

struct KeyOutput {
    var code: UInt16
    var down: Bool
    var flags: CGEventFlags
    var modifier = false
    var repeating = false
}

// Pure transitions; only the controller posts the returned events.
final class MappingEngine {
    private struct Stroke { let binding: KeyBinding; let keys: [Key] }
    private var held: [String:Stroke] = [:]
    private var order: [String] = []
    private var repeatAt: TimeInterval = .infinity
    var repeatDelay: TimeInterval = 0.45
    var repeatInterval: TimeInterval = 0.04
    private let modifiers: [UInt16:CGEventFlags] = [59:.maskControl,62:.maskControl,56:.maskShift,60:.maskShift,58:.maskAlternate,61:.maskAlternate,55:.maskCommand,54:.maskCommand]
    private func state() -> (regular:Set<UInt16>, mods:Set<UInt16>) {
        var regular = Set<UInt16>(), mods = Set<UInt16>()
        var requested: CGEventFlags = []
        for stroke in held.values {
            for key in stroke.keys {
                if modifiers[key.code] != nil { mods.insert(key.code) } else { regular.insert(key.code) }
            }
            requested.formUnion(stroke.binding.flags)
        }
        let canonical: [(CGEventFlags,UInt16)] = [(.maskControl,59),(.maskShift,56),(.maskAlternate,58),(.maskCommand,55)]
        for (flag,code) in canonical where requested.contains(flag) {
            if !mods.contains(where:{ modifiers[$0] == flag }) { mods.insert(code) }
        }
        return (regular,mods)
    }
    private func flags(_ set: Set<UInt16>) -> CGEventFlags {
        set.reduce(CGEventFlags()) { $0.union(modifiers[$1] ?? []) }
    }
    func key(usage: Int, down: Bool, source: String, bindings: [KeyBinding], now: TimeInterval) -> [KeyOutput] {
        let before = state()
        if down {
            guard held[source] == nil else { return [] }
            let binding = bindings.first(where:{$0.source == usage}) ?? KeyBinding(source:usage,target:usage)
            guard binding.valid else { return [] }
            let targets = binding.targetUsages.compactMap { usage in keys.first { $0.usage == usage } }
            held[source] = Stroke(binding:binding,keys:targets)
            order.append(source); repeatAt = now + repeatDelay
        } else {
            guard held.removeValue(forKey:source) != nil else { return [] }
            order.removeAll { $0 == source }; repeatAt = now + repeatDelay
        }
        return difference(before,state())
    }
    private func difference(_ old: (regular:Set<UInt16>,mods:Set<UInt16>),_ new: (regular:Set<UInt16>,mods:Set<UInt16>)) -> [KeyOutput] {
        var result: [KeyOutput] = []
        var current = old.mods
        for code in old.regular.subtracting(new.regular).sorted() { result.append(KeyOutput(code:code,down:false,flags:flags(current))) }
        for code in old.mods.subtracting(new.mods).sorted() {
            current.remove(code); result.append(KeyOutput(code:code,down:false,flags:flags(current),modifier:true))
        }
        for code in new.mods.subtracting(old.mods).sorted() {
            current.insert(code); result.append(KeyOutput(code:code,down:true,flags:flags(current),modifier:true))
        }
        for code in new.regular.subtracting(old.regular).sorted() { result.append(KeyOutput(code:code,down:true,flags:flags(current))) }
        return result
    }
    func repeatEvent(now: TimeInterval) -> KeyOutput? {
        guard now >= repeatAt, let source = order.reversed().first(where:{ if let s = held[$0] { return s.keys.contains { modifiers[$0.code] == nil } }; return false }), let stroke = held[source], let key = stroke.keys.first else { return nil }
        // Shortcut chords are single-shot. Ordinary held keys repeat for text entry.
        guard stroke.binding.flags.isEmpty, stroke.keys.count == 1, key.usage != 57 else { return nil }
        repeatAt = now + repeatInterval
        return KeyOutput(code:key.code,down:true,flags:flags(state().mods),repeating:true)
    }
    func releaseAll() -> [KeyOutput] {
        let before = state(); held.removeAll(); order.removeAll(); repeatAt = .infinity
        return difference(before,state())
    }
}
