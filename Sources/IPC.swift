import Foundation
import Darwin

func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw NSError(domain:"Tartarus",code:1,userInfo:[NSLocalizedDescriptionKey:"辅助进程通信路径过长"])
    }
    withUnsafeMutableBytes(of:&address.sun_path) { raw in
        for (i,b) in bytes.enumerated() { raw[i] = UInt8(bitPattern:b) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}
func socketConnect(_ fd: Int32, _ path: String) throws -> Int32 {
    var a = try makeAddress(path)
    return withUnsafePointer(to:&a) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}
func socketBind(_ fd: Int32, _ path: String) throws -> Int32 {
    var a = try makeAddress(path)
    return withUnsafePointer(to:&a) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}
func disableSigpipe(_ fd: Int32) {
    var yes: Int32 = 1
    _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
}
func makeBlocking(_ fd: Int32) {
    let flags = fcntl(fd,F_GETFL)
    if flags >= 0 { _ = fcntl(fd,F_SETFL,flags & ~O_NONBLOCK) }
}
@discardableResult func sendLine(_ fd: Int32,_ text: String) -> Bool {
    let data = Array((text+"\n").utf8)
    return data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.send(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,0)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
func quotedShell(_ s: String) -> String { "'" + s.replacingOccurrences(of:"'",with:"'\\''") + "'" }
