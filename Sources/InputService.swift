import Foundation
import Darwin
import Security
import SystemConfiguration
import IOKit.hid

// A versioned, fixed protocol: select a Tartarus location, then heartbeat/stop.
// No file access, shell commands, profile loading, or event injection in the daemon.
enum InputService {
    static let label = "local.tartarus.light.input"
    static let appPath = "/Library/PrivilegedHelperTools/" + label + ".app"
    static let executable = appPath + "/Contents/MacOS/TartarusLight"
    static let plist = "/Library/LaunchDaemons/" + label + ".plist"
    static let socketPath = "/var/run/" + label + ".sock"
    static let flag = "--input-service"

    static func location(from request: String) -> UInt32? {
        let fields = request.split(separator:" ")
        guard fields.count == 3, fields[0] == "open", fields[1] == "1",
              let location = UInt32(fields[2]), location != 0 else { return nil }
        return location
    }
    static func ownRequirement() -> SecRequirement? {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
    static func installedMatchesApp(at path: String = executable) -> Bool {
        var code: SecStaticCode?
        guard let requirement = ownRequirement(),
              SecStaticCodeCreateWithPath(URL(fileURLWithPath:path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    static func trustedPeer(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue:token))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout.size(ofValue:token), let requirement = ownRequirement() else { return false }
        let tokenData = withUnsafeBytes(of:&token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit:tokenData] as CFDictionary,[],&code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    static func consoleUser() -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil,&uid,&gid) != nil, uid != 0 else { return nil }
        return uid
    }
    static var inputAccessLine: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "access granted"
        case kIOHIDAccessTypeDenied: return "access denied"
        default: return "access unknown"
        }
    }
    static func request(_ fd: Int32) -> String? {
        var data = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var item = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            guard poll(&item,1,100) >= 0 else { return nil }
            var byte: UInt8 = 0
            let count = recv(fd,&byte,1,MSG_DONTWAIT)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return nil
            }
            if byte == 10 { return String(data:data,encoding:.utf8) }
            data.append(byte)
            if data.count > 64 { return nil }
        }
        return nil
    }
    static func main() {
        guard geteuid() == 0, CommandLine.arguments.count == 2 else { exit(77) }
        let server = socket(AF_UNIX,SOCK_STREAM,0)
        guard server >= 0 else { exit(66) }
        // /var/run is root-owned; no unprivileged process can replace this path.
        unlink(socketPath)
        do { guard try socketBind(server,socketPath) == 0, chmod(socketPath,0o666) == 0, listen(server,8) == 0 else { exit(67) } }
        catch { exit(67) }
        while true {
            let fd = accept(server,nil,nil)
            if fd < 0 { if errno == EINTR { continue }; exit(68) }
            autoreleasepool {
                defer { shutdown(fd,SHUT_RDWR); close(fd) }
                disableSigpipe(fd)
                _ = fcntl(fd,F_SETFL,O_NONBLOCK)
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(fd,&uid,&gid) == 0, consoleUser() == uid, trustedPeer(fd) else { return }
                guard let line = request(fd) else { return }
                if line == "check 1" {
                    sendLine(fd,inputAccessLine)
                    return
                }
                guard let location = location(from:line) else { return }
                _ = InputReader(fd).run(location:location,consoleUID:uid)
            }
        }
    }

    static var plistData: Data {
        try! PropertyListSerialization.data(fromPropertyList:[
            "Label":label, "ProgramArguments":[executable,flag],
            "RunAtLoad":true, "KeepAlive":true, "ThrottleInterval":5,
            "ProcessType":"Interactive"
        ],format:.xml,options:0)
    }
    static func installCommand(source: String) -> String {
        let xml = String(data:plistData,encoding:.utf8)!
        let staging = appPath + ".installing"
        return "set -e\n" +
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools\n" +
            "/bin/rm -rf " + quotedShell(staging) + "\n" +
            "/usr/bin/ditto " + quotedShell(source) + " " + quotedShell(staging) + "\n" +
            "/usr/sbin/chown -R root:wheel " + quotedShell(staging) + "\n" +
            "/bin/chmod -R go-w " + quotedShell(staging) + "\n" +
            "/usr/bin/codesign --verify --deep --strict " + quotedShell(staging) + "\n" +
            "/bin/launchctl bootout system " + quotedShell(plist) + " 2>/dev/null || true\n" +
            "/bin/rm -rf " + quotedShell(appPath) + "\n" +
            "/bin/mv " + quotedShell(staging) + " " + quotedShell(appPath) + "\n" +
            "/usr/bin/printf %s " + quotedShell(xml) + " > " + quotedShell(plist) + "\n" +
            "/usr/sbin/chown root:wheel " + quotedShell(plist) + "\n" +
            "/bin/chmod 644 " + quotedShell(plist) + "\n" +
            "/bin/launchctl enable system/" + label + "\n" +
            "/bin/launchctl bootstrap system " + quotedShell(plist)
    }
    static var uninstallCommand: String {
        "/bin/launchctl bootout system " + quotedShell(plist) + " 2>/dev/null || true\n" +
        "/bin/rm -f " + [plist,socketPath].map(quotedShell).joined(separator:" ") + "\n" +
        "/bin/rm -rf " + [appPath,appPath+".installing"].map(quotedShell).joined(separator:" ")
    }
    static func authorize(_ command: String) throws {
        let literal = command.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
        process.arguments = ["-e","do shell script \""+literal+"\" with administrator privileges"]
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain:label,code:Int(process.terminationStatus),userInfo:[NSLocalizedDescriptionKey:String(data:data,encoding:.utf8) ?? "Service installation failed"])
        }
    }
}
