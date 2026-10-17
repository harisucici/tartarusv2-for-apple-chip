import Foundation
import ApplicationServices
import Darwin

func runMappingChecks() {
    precondition(Set(keys.map(\.usage)).count == keys.count)
    let e = MappingEngine()
    let bindings = [KeyBinding(source:30,target:6,command:true),KeyBinding(source:31,target:6)]
    let down = e.key(usage:30,down:true,source:"1:30",bindings:bindings,now:0)
    precondition(down.count == 2 && down[0].modifier && down[0].code == 55 && down[0].down && down[1].code == 8 && down[1].flags.contains(.maskCommand))
    precondition(e.key(usage:30,down:true,source:"1:30",bindings:bindings,now:0.1).isEmpty)
    let up = e.key(usage:30,down:false,source:"1:30",bindings:bindings,now:0.2)
    precondition(up.count == 2 && up[0].code == 8 && !up[0].down && up[1].modifier && !up[1].down && up[1].flags.isEmpty)
    let overlap = [KeyBinding(source:30,target:6),KeyBinding(source:31,target:6)]
    precondition(e.key(usage:30,down:true,source:"1:30",bindings:overlap,now:1).count == 1)
    precondition(e.key(usage:31,down:true,source:"2:31",bindings:overlap,now:1).isEmpty)
    precondition(e.key(usage:30,down:false,source:"1:30",bindings:overlap,now:2).isEmpty)
    precondition(e.key(usage:31,down:false,source:"2:31",bindings:overlap,now:2).count == 1)
    let ordinary = e.key(usage:4,down:true,source:"1:4",bindings:[],now:3)
    precondition(ordinary.count == 1 && ordinary[0].code == 0)
    precondition(e.repeatEvent(now:3.1) == nil)
    precondition(e.repeatEvent(now:4)?.repeating == true)
    precondition(e.releaseAll().count == 1 && e.repeatEvent(now:10) == nil && e.releaseAll().isEmpty)
    _ = e.key(usage:30,down:true,source:"1:30",bindings:bindings,now:11)
    precondition(e.repeatEvent(now:12) == nil) // shortcuts are single-shot
    let released = e.releaseAll()
    precondition(released.count == 2 && released.last?.flags.isEmpty == true)
    let chord = KeyBinding(source:30,target:6,command:true,shift:true,extraTargets:[25])
    let comboDown = e.key(usage:30,down:true,source:"1:30",bindings:[chord],now:20)
    precondition(comboDown.count == 4 && comboDown.prefix(2).allSatisfy { $0.modifier && $0.down })
    precondition(Set(comboDown.suffix(2).map(\.code)) == Set([8,9]))
    precondition(comboDown.suffix(2).allSatisfy { $0.flags.contains([.maskCommand,.maskShift]) })
    precondition(e.repeatEvent(now:22) == nil)
    // A second held source shares V; releasing the combo must not release that V.
    _ = e.key(usage:31,down:true,source:"1:31",bindings:[KeyBinding(source:31,target:25)],now:23)
    let partial = e.key(usage:30,down:false,source:"1:30",bindings:[],now:24)
    precondition(partial.count == 3 && partial.first?.code == 8 && partial.allSatisfy { !$0.down && $0.code != 9 })
    precondition(e.releaseAll().map(\.code) == [9])
    precondition(!KeyBinding(source:30,target:6,extraTargets:[6]).valid)
    precondition(!KeyBinding(source:30,target:6,extraTargets:[4,5,7,8]).valid)
    let legacyBinding = Data("{\"id\":\"E37BD5DF-55CD-4B98-9EC4-EA6B1BB17872\",\"source\":30,\"target\":6,\"command\":false,\"shift\":false,\"option\":false,\"control\":false}".utf8)
    precondition(try! JSONDecoder().decode(KeyBinding.self,from:legacyBinding).targetUsages == [6])
    let comboStored = try! JSONEncoder().encode(chord)
    precondition(try! JSONDecoder().decode(KeyBinding.self,from:comboStored).display == "⇧⌘C + V")
    let loc: UInt32 = 17825792
    precondition(DeviceScope.accepts(vendor:5426,product:555,location:loc,selected:loc,page:1,usage:6))
    precondition(!DeviceScope.accepts(vendor:1133,product:555,location:loc,selected:loc,page:1,usage:6))
    precondition(!DeviceScope.accepts(vendor:5426,product:555,location:loc+1,selected:loc,page:1,usage:6))
    precondition(!DeviceScope.accepts(vendor:5426,product:555,location:loc,selected:loc,page:1,usage:2))
    precondition(!DeviceScope.accepts(vendor:5426,product:555,location:0,selected:0,page:1,usage:6))
    let c = MappingController(loadProfile:false)
    var captured: [KeyOutput] = []
    c.eventSink = { captured.append($0) }
    c.bindings = bindings
    c.process(usage:30,down:true,source:"1:30")
    precondition(captured.isEmpty) // inactive controller cannot post input
    c.running = true; c.process(usage:30,down:true,source:"1:30")
    precondition(captured.count == 2)
    c.stop()
    precondition(captured.count == 4 && captured.last?.flags.isEmpty == true && !c.running)
    c.receive("key invalid 30 1"); c.receive("key 123 30 1")
    precondition(captured.count == 4)
    c.receive("ready")
    precondition(!c.running) // A late callback after stop cannot reactivate mapping.
    c.monitoring = true
    c.receive("key 123 31 1")
    precondition(c.lastKey == "2 · HID 31" && captured.count == 4 && !c.running)
    c.receive("key 123 31 0"); c.receive("key invalid 4 1")
    precondition(c.lastKey == "2 · HID 31" && captured.count == 4)
    c.starting = true; c.receive("key 123 4 1")
    precondition(c.lastKey == "2 · HID 31")
    c.stop()
    precondition(!c.monitoring && !c.starting && captured.count == 4)
    let p = MappingProfile(bindings:bindings,location:loc)
    precondition(try! JSONDecoder().decode(MappingProfile.self,from:JSONEncoder().encode(p)).location == loc)
    precondition(quotedShell("a'b") == "'a'\\''b'")
    let readerArguments = ["/app/TartarusLight",ReaderInvocation.flag,"/tmp/tartarus-abc/input.sock","17825792"]
    precondition(ReaderInvocation.parse(readerArguments)?.location == loc)
    precondition(ReaderInvocation.parse(["app",ReaderInvocation.flag,"/tmp/tartarus-abc/input.sock","0"]) == nil)
    precondition(ReaderInvocation.parse(["app",ReaderInvocation.flag,"/tmp/tartarus-abc/../input.sock","123"]) == nil)
    precondition(ReaderInvocation.parse(["app",ReaderInvocation.flag,"/tmp/other.sock","123"]) == nil)
    precondition(ReaderInvocation.parse(["app","--wrong","/tmp/tartarus-abc/input.sock","123"]) == nil)
    precondition(ReaderInvocation.parse(readerArguments+["extra"]) == nil)
    var pair: [Int32] = [-1,-1]
    precondition(socketpair(AF_UNIX,SOCK_STREAM,0,&pair) == 0)
    defer { close(pair[0]); close(pair[1]) }
    disableSigpipe(pair[0]); disableSigpipe(pair[1])
    _ = fcntl(pair[0],F_SETFL,O_NONBLOCK)
    makeBlocking(pair[0])
    precondition(fcntl(pair[0],F_GETFL) & O_NONBLOCK == 0)
    precondition(sendLine(pair[1],"ready"))
    var buffer = [UInt8](repeating:0,count:16)
    let count = recv(pair[0],&buffer,buffer.count,0)
    precondition(count == 6 && String(bytes:buffer.prefix(count),encoding:.utf8) == "ready\n")
    print("PASS: mapping chord order, duplicate callbacks, overlapping destinations, repeat/stop releases, inactive controller, device isolation and configuration. No OS input posted.")
}
