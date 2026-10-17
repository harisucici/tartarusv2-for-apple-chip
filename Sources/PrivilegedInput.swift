import Foundation
import Darwin

// The socket carries fixed input records only. There is no privileged command API.
final class InputSession {
    let lock = NSLock()
    var listener: Int32 = -1
    var connection: Int32 = -1
    var cancelled = false
    var process: Process?
    var directory: URL?
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if connection >= 0 { sendLine(connection,"x"); shutdown(connection,SHUT_RDWR) }
        if listener >= 0 { shutdown(listener,SHUT_RDWR) }
        if let p = process, p.isRunning { p.terminate() }
    }
    func ping() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !cancelled && connection >= 0 && sendLine(connection,"p")
    }
}

final class PrivilegedInput {
    private var session: InputSession?
    func stop() { session?.cancel(); session = nil }
    func ping() -> Bool { session?.ping() ?? false }
    func start(location: UInt32, receive: @escaping (String) -> Void) throws {
        stop()
        let s = InputSession()
        let folder = URL(fileURLWithPath:"/tmp/tartarus-"+String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        s.directory = folder
        let path = folder.appendingPathComponent("input.sock").path
        let server = socket(AF_UNIX,SOCK_STREAM,0)
        guard server >= 0 else { try? FileManager.default.removeItem(at:folder); throw failure("无法建立本机通信") }
        do {
            guard try socketBind(server,path) == 0, listen(server,1) == 0 else { throw failure("无法监听辅助进程") }
            _ = chmod(path,0o600)
            _ = fcntl(server,F_SETFL,O_NONBLOCK)
        } catch {
            close(server); try? FileManager.default.removeItem(at:folder); throw error
        }
        s.listener = server; session = s
        guard let tool = Bundle.main.executableURL?.path, FileManager.default.isExecutableFile(atPath:tool) else {
            close(server); s.listener = -1; try? FileManager.default.removeItem(at:folder); session = nil
            throw failure("无法定位 Tartarus Light 可执行文件，请使用完整应用")
        }
        let command = quotedShell(tool)+" "+ReaderInvocation.flag+" "+quotedShell(path)+" "+String(location)
        // Encode AppleScript separately from shell quoting; profiles never enter either language.
        let literal = command.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
        p.arguments = ["-e","do shell script \""+literal+"\" with administrator privileges"]
        let errors = Pipe(); p.standardError = errors; p.standardOutput = Pipe(); s.process = p
        p.terminationHandler = { [weak self, weak s] process in
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data:data,encoding:.utf8) ?? ""
            DispatchQueue.main.async {
                guard let self = self, let s = s, self.session === s else { return }
                s.lock.lock(); let cancelled = s.cancelled; s.lock.unlock()
                if !cancelled && process.terminationStatus != 0 {
                    receive(detail.contains("-128") ? "error 已取消管理员授权" : "error 辅助进程退出（\(process.terminationStatus)）："+String(detail.prefix(500)))
                }
            }
        }
        do { try p.run() } catch {
            session = nil; close(server); s.listener = -1; try? FileManager.default.removeItem(at:folder); throw error
        }
        DispatchQueue.global(qos:.userInteractive).async { [weak self] in
            defer {
                s.lock.lock(); s.listener = -1; s.lock.unlock()
                close(server); try? FileManager.default.removeItem(at:folder)
            }
            var fd: Int32 = -1
            while fd < 0 {
                s.lock.lock(); let cancelled = s.cancelled; s.lock.unlock()
                if cancelled { return }
                var item = pollfd(fd:server,events:Int16(POLLIN),revents:0)
                let result = poll(&item,1,250)
                if result < 0 && errno != EINTR { return }
                if result > 0 { fd = accept(server,nil,nil) }
            }
            guard fd >= 0 else { return }
            // Darwin may inherit O_NONBLOCK from the listening socket. A transient
            // EAGAIN before the helper's ready message is not an EOF.
            makeBlocking(fd)
            defer {
                s.lock.lock(); s.connection = -1; s.lock.unlock()
                shutdown(fd,SHUT_RDWR); close(fd)
            }
            var uid: uid_t = 1; var gid: gid_t = 1
            guard getpeereid(fd,&uid,&gid) == 0, uid == 0 else {
                DispatchQueue.main.async { if self?.session === s { receive("error 辅助进程身份验证失败") } }; return
            }
            disableSigpipe(fd)
            s.lock.lock()
            if s.cancelled { s.lock.unlock(); return }
            s.connection = fd; s.lock.unlock()
            var pending = Data(); var buffer = [UInt8](repeating:0,count:2048)
            while true {
                let n = recv(fd,&buffer,buffer.count,0)
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var item = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                    _ = poll(&item,1,250); continue
                }
                if n <= 0 { break }
                pending.append(contentsOf:buffer.prefix(n))
                if pending.count > 16384 { break }
                while let end = pending.firstIndex(of:10) {
                    let line = String(data:pending.prefix(upTo:end),encoding:.utf8) ?? ""
                    pending.removeSubrange(...end)
                    DispatchQueue.main.async { if self?.session === s { receive(line) } }
                }
            }
            // Allow a nonzero process exit to report its diagnostic first.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { if self?.session === s { receive("closed") } }
        }
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain:"TartarusInput",code:1,userInfo:[NSLocalizedDescriptionKey:text])
    }
}
