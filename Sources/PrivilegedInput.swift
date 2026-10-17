import Foundation
import Darwin

final class InputSession {
    let lock = NSLock()
    var connection: Int32 = -1
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        connection = fd; return true
    }
    func detach() { lock.lock(); connection = -1; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if connection >= 0 { sendLine(connection,"x"); shutdown(connection,SHUT_RDWR) }
    }
    func ping() -> Bool { command("p") }
    func command(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && connection >= 0 && sendLine(connection,value)
    }
}

final class PrivilegedInput {
    private var session: InputSession?
    func stop() { session?.cancel(); session = nil }
    func ping() -> Bool { session?.ping() ?? false }
    func checkAccess() -> Bool { session?.command("c") ?? false }
    func install(completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos:.userInitiated).async {
            var message: String?
            do { try InputService.authorize(InputService.installCommand(source:Bundle.main.bundleURL.path)) }
            catch { message = error.localizedDescription }
            DispatchQueue.main.async { completion(message) }
        }
    }
    func start(location: UInt32, allowInstallation: Bool = true, receive: @escaping (String) -> Void) throws {
        stop()
        guard location != 0, Bundle.main.bundleURL.pathExtension == "app" else {
            throw NSError(domain:InputService.label,code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid device or application"])
        }
        let s = InputSession(); session = s
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            func deliver(_ line: String) {
                DispatchQueue.main.async { [weak self] in
                    if self?.session === s, !s.isCancelled { receive(line) }
                }
            }
            do {
                // Only installation or a changed signed executable needs authorization.
                if !InputService.installedMatchesApp() {
                    guard allowInstallation else { deliver("error "+NSLocalizedString("service.needs_installation",comment:"")); return }
                    try InputService.authorize(InputService.installCommand(source:Bundle.main.bundleURL.path))
                }
                guard !s.isCancelled else { return }
                var fd: Int32 = -1
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !s.isCancelled {
                    let candidate = socket(AF_UNIX,SOCK_STREAM,0)
                    guard candidate >= 0 else { break }
                    if (try? socketConnect(candidate,InputService.socketPath)) == 0 { fd = candidate; break }
                    close(candidate)
                    Thread.sleep(forTimeInterval:0.1)
                }
                guard fd >= 0 else { deliver("error "+NSLocalizedString("service.unavailable",comment:"")); return }
                defer { s.detach(); shutdown(fd,SHUT_RDWR); close(fd) }
                disableSigpipe(fd)
                var uid: uid_t = 1, gid: gid_t = 1
                guard getpeereid(fd,&uid,&gid) == 0, uid == 0 else { deliver("error Service identity check failed"); return }
                // Bound both reads and writes. A stalled service must not block UI shutdown.
                var timeout = timeval(tv_sec:2,tv_usec:0)
                _ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
                _ = setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
                guard s.attach(fd), sendLine(fd,"open 1 \(location)") else { return }
                var pending = Data(), buffer = [UInt8](repeating:0,count:2048)
                while !s.isCancelled {
                    let n = recv(fd,&buffer,buffer.count,0)
                    if n < 0 && errno == EINTR { continue }
                    if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        if !s.ping() { break }
                        continue
                    }
                    if n <= 0 { break }
                    pending.append(contentsOf:buffer.prefix(n))
                    if pending.count > 16384 { break }
                    while let end = pending.firstIndex(of:10) {
                        let line = String(data:pending.prefix(upTo:end),encoding:.utf8) ?? ""
                        pending.removeSubrange(...end)
                        deliver(line)
                    }
                }
                deliver("closed")
            } catch { deliver("error "+error.localizedDescription) }
        }
    }
    func uninstall(completion: @escaping (String?) -> Void) {
        stop()
        DispatchQueue.global(qos:.userInitiated).async {
            var message: String?
            do { try InputService.authorize(InputService.uninstallCommand) }
            catch { message = error.localizedDescription }
            DispatchQueue.main.async { completion(message) }
        }
    }
}


enum PermissionCheck: String {
    case granted, denied, unknown
    init(line: String) {
        switch line {
        case "access granted": self = .granted
        case "access denied": self = .denied
        default: self = .unknown
        }
    }
}
enum InputServiceState: String { case missing, update, unavailable, ready, checking }
struct InputServiceInspection {
    var state: InputServiceState
    var access: PermissionCheck = .unknown
    static func inspect() -> InputServiceInspection {
        guard FileManager.default.fileExists(atPath:InputService.executable) else { return Self(state:.missing) }
        guard InputService.installedMatchesApp() else { return Self(state:.update) }
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { return Self(state:.unavailable) }
        defer { shutdown(fd,SHUT_RDWR); close(fd) }
        disableSigpipe(fd)
        _ = fcntl(fd,F_SETFL,O_NONBLOCK)
        guard (try? socketConnect(fd,InputService.socketPath)) == 0 else { return Self(state:.unavailable) }
        var uid: uid_t = 1, gid: gid_t = 1
        guard getpeereid(fd,&uid,&gid) == 0, uid == 0, sendLine(fd,"check 1") else { return Self(state:.unavailable) }
        guard let line = InputService.request(fd), line.hasPrefix("access ") else { return Self(state:.unavailable) }
        return Self(state:.ready,access:PermissionCheck(line:line))
    }
}
