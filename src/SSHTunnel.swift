import Foundation

private func loopback(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    return addr
}

private func freeLocalPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    var addr = loopback(port: 0)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = bind(fd, $0, len)
            _ = getsockname(fd, $0, &len)
        }
    }
    return UInt16(bigEndian: addr.sin_port)
}

private func portAccepts(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    var addr = loopback(port: port)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}

// Tunnel through the system /usr/bin/ssh, so ~/.ssh/config, keys, the agent and ProxyJump all work.
// If ssh dies after the tunnel was established, it is restarted on the same local port.
final class SSHTunnel: @unchecked Sendable {
    // Posted on the main thread (object: the tunnel) when the tunnel drops or comes back. Every window sharing the
    // tunnel (tabs) observes it; `connected` has the new state.
    static let statusNotification = Notification.Name("SSHTunnelStatus")

    let localPort: UInt16
    // true once started and while up; false before start and while dropped and reconnecting. Main thread.
    private(set) var connected = false
    private let sshHost, host, port: String
    private let lock = NSLock()
    private var task: Process?, stopped = false, established = false // under `lock`

    init(sshHost: String, remoteHost host: String, remotePort port: String) {
        self.sshHost = sshHost
        self.host = host
        self.port = port
        localPort = freeLocalPort()
    }

    deinit { stop() }

    // Blocks until the local port accepts connections or ssh fails. Don't call on the main thread.
    func start() throws {
        if let message = launchAndWait() {
            stop()
            throw DBError(String(format: L("SSH tunnel: %@"), message))
        }
        lock.withLock { established = true }
        DispatchQueue.main.sync { connected = true } // read on the main thread once connect() hands it over
    }

    // nil when the tunnel is up, otherwise an error message.
    private func launchAndWait() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-N",
            "-L", "127.0.0.1:\(localPort):\(host):\(port)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes", // no password prompts: the app has no terminal
            "-o", "ForwardAgent=no", // the tunnel only forwards a port, whatever ~/.ssh/config says for the host
            "-o", "ForwardX11=no",
            "--", sshHost,
        ]
        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        task.standardOutput = FileHandle.nullDevice
        task.terminationHandler = { [weak self] t in self?.taskDidExit(t) }

        let wasStopped = lock.withLock {
            if !stopped { self.task = task }
            return stopped
        }
        if wasStopped { return L("stopped") }
        do { try task.run() } catch { return error.localizedDescription }

        for _ in 0..<100 { // up to ~20 s: ConnectTimeout plus login
            if !task.isRunning {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return err.isEmpty ? String(format: L("ssh exited with code %d"), task.terminationStatus) : err
            }
            if portAccepts(localPort) { return nil }
            usleep(200_000)
        }
        task.terminate()
        return L("timed out waiting for the connection")
    }

    private func taskDidExit(_ t: Process) {
        guard lock.withLock({ !stopped && established && t === task }) else { return }
        report(false)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            // If this fails, ssh exits again and taskDidExit retries.
            if self.launchAndWait() == nil { self.report(true) }
        }
    }

    func report(_ connected: Bool) {
        DispatchQueue.main.async {
            self.connected = connected
            NotificationCenter.default.post(name: Self.statusNotification, object: self)
        }
    }

    func stop() {
        let task = lock.withLock {
            stopped = true
            return self.task
        }
        if task?.isRunning == true { task?.terminate() }
    }
}
