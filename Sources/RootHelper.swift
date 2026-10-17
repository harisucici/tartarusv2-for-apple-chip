// Short-lived input mode of the same Tartarus Light executable. No UI, profile
// loading, installation, shell execution or event injection runs in this mode.
import Foundation
import IOKit.hid
import SystemConfiguration
import Darwin

final class InputReader {
    let fd: Int32
    var devices: [IOHIDDevice] = []
    var manager: IOHIDManager?
    var alive = true
    init(_ fd: Int32) { self.fd = fd }
    func output(_ line: String) { if !sendLine(fd,line) { alive = false } }
    func closeDevices() {
        for d in devices {
            IOHIDDeviceUnscheduleFromRunLoop(d,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputValueCallback(d,nil,nil)
            IOHIDDeviceClose(d,0)
        }
        devices.removeAll(); manager = nil
    }
    func run(location: UInt32, consoleUID: uid_t? = nil) -> Int32 {
        let m = IOHIDManagerCreate(kCFAllocatorDefault,0); manager = m
        IOHIDManagerSetDeviceMatching(m,DeviceScope.matching(location:location) as CFDictionary)
        guard let ds = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, !ds.isEmpty else { output("error 未找到 Tartarus V2 键盘接口"); return 2 }
        defer { closeDevices() }
        for d in ds {
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(d,key as CFString) as? NSNumber)?.intValue ?? 0 }
            guard DeviceScope.accepts(vendor:number(kIOHIDVendorIDKey),product:number(kIOHIDProductIDKey),location:UInt32(clamping:number(kIOHIDLocationIDKey)),selected:location,page:number(kIOHIDPrimaryUsagePageKey),usage:number(kIOHIDPrimaryUsageKey)) else {
                output("error 设备身份检查失败，未接管输入"); return 4
            }
            let result = IOHIDDeviceOpen(d,IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if result != kIOReturnSuccess {
                output(String(format:"error 独占接口失败 0x%08x（管理员进程）；可能仍有驱动占用或系统输入权限限制",UInt32(bitPattern:result)))
                return 3
            }
            devices.append(d)
            IOHIDDeviceRegisterInputValueCallback(d,{ ctx,_,_,value in
                guard let ctx = ctx else { return }
                let reader = Unmanaged<InputReader>.fromOpaque(ctx).takeUnretainedValue()
                let element = IOHIDValueGetElement(value)
                guard IOHIDElementGetUsagePage(element) == 7 else { return }
                let usage = IOHIDElementGetUsage(element)
                guard usage >= 4 && usage <= 231 else { return }
                var id: UInt64 = 0
                _ = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(IOHIDElementGetDevice(element)),&id)
                reader.output("key \(id) \(usage) \(IOHIDValueGetIntegerValue(value) != 0 ? 1 : 0)")
            },Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceRegisterRemovalCallback(d,{ ctx,_,_ in
                guard let ctx = ctx else { return }
                let reader = Unmanaged<InputReader>.fromOpaque(ctx).takeUnretainedValue()
                reader.output("error 设备已断开，映射已停止"); reader.alive = false
            },Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(d,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
        }
        output("ready")
        var heartbeat = Date()
        while alive {
            if let consoleUID, InputService.consoleUser() != consoleUID { break }
            if Date().timeIntervalSince(heartbeat) > 5 { break }
            CFRunLoopRunInMode(.defaultMode,0.1,false)
            var data = [UInt8](repeating:0,count:64)
            let n = recv(fd,&data,data.count,MSG_DONTWAIT)
            if n == 0 { break }
            if n > 0 {
                if data.prefix(n).contains(120) { break } // 'x': release and exit.
                if data.prefix(n).contains(99) { output(InputService.inputAccessLine) } // 'c': status only.
                heartbeat = Date()
            }
            if n < 0 && errno != EAGAIN && errno != EINTR { break }
            if Date().timeIntervalSince(heartbeat) > 5 { break }
        }
        return 0
    }
}
enum ReaderInvocation {
    static let flag = "--input-reader"
    static func parse(_ arguments:[String]) -> (path:String,location:UInt32)? {
        guard arguments.count == 4, arguments[1] == flag,
              let location = UInt32(arguments[3]), location != 0 else { return nil }
        let path = arguments[2]
        guard path.hasPrefix("/tmp/tartarus-"), path.hasSuffix("/input.sock"),
              !path.contains(".."), path.utf8.count < 104 else { return nil }
        return (path,location)
    }
}
enum InputReaderMain {
    static func main() {
        guard geteuid() == 0 else { fputs("This helper requires system administrator authorization.\n",stderr); exit(77) }
        guard let invocation = ReaderInvocation.parse(CommandLine.arguments) else { fputs("Invalid device scope arguments.\n",stderr); exit(64) }
        let path = invocation.path, location = invocation.location
        var info = stat(); var consoleUID: uid_t = 0; var consoleGID: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil,&consoleUID,&consoleGID) != nil, consoleUID != 0,
              lstat(path,&info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == consoleUID else { fputs("Console user or socket ownership check failed.\n",stderr); exit(65) }
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { exit(66) }
        disableSigpipe(fd)
        do { guard try socketConnect(fd,path) == 0 else { exit(67) } } catch { exit(67) }
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        guard getpeereid(fd,&peerUID,&peerGID) == 0, peerUID == consoleUID else { fputs("GUI peer identity check failed.\n",stderr); close(fd); exit(68) }
        // A stalled GUI must not leave the keyboard seized behind a blocking write.
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        let result = InputReader(fd).run(location:location)
        shutdown(fd,SHUT_RDWR); close(fd); exit(result)
    }
}
