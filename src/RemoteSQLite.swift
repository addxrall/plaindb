import Foundation

private let stderrKept = 4096     // the end of ssh's messages, for errors
private let linesBeforeHello = 100 // e.g. a banner printed by the remote shell

// writing to a helper that died must be an error, not the end of the app
private let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

// One process running PlainDB's SQLite helper (Resources/sqlite_remote.py), usually ssh starting it on a server:
// JSON lines over its stdin and stdout. Blocking; call it on the connection's queue.
final class RemoteSQLite: @unchecked Sendable {
    private let command: [String]
    private let helper: String
    private var path = ""
    private var readOnly = false, started = false
    private var task: Process?
    private var input: FileHandle?, output: FileHandle?
    private var buffer = Data() // stdout read but not yet split into lines
    private let lock = NSLock()
    private var stderrData = Data() // under `lock`: the stderr handler runs on its own thread
    private var lastId = 0

    // command: what to launch (ssh … python3 …, or python3 itself in tests); helper: the helper's source.
    init(command: [String], helper: String) {
        _ = ignoreSIGPIPE
        self.command = command
        self.helper = helper
    }

    deinit { stop() }

    private func stderrTail() -> String {
        let data = lock.withLock { stderrData }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Launches the command, sends the helper and its config, and waits for its hello.
    func start(path: String, readOnly: Bool) throws {
        endProcess()
        self.path = path
        self.readOnly = readOnly
        started = true
        buffer = Data()
        lock.withLock { stderrData = Data() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command[0])
        task.arguments = Array(command.dropFirst())
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self, !data.isEmpty else { return }
            self.lock.withLock {
                self.stderrData.append(data)
                if self.stderrData.count > stderrKept { self.stderrData = self.stderrData.suffix(stderrKept) }
            }
        }
        do { try task.run() } catch { throw DBError(error.localizedDescription) }
        self.task = task
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading

        // the helper's source and config travel on stdin, so nothing from the user reaches the remote shell
        let config = try! JSONSerialization.data(withJSONObject: ["path": path, "readonly": readOnly])
        var intro = Data(helper.utf8).base64EncodedData()
        intro.append(10)
        intro.append(config)
        intro.append(10)
        try? input?.write(contentsOf: intro) // a failure shows up as the missing hello below

        for _ in 0..<linesBeforeHello {
            guard let line = readLine() else { break }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], message["id"] == nil else {
                continue // not the helper speaking yet
            }
            if message["hello"] as? String == "plaindb" { return }
            if let error = message["error"] as? String {
                endProcess()
                throw DBError(error)
            }
        }
        if task.isRunning { task.terminate() } // talked a lot, never said hello
        let error = exitError()
        endProcess()
        throw error
    }

    // Why the process ended (or is about to): ssh's message, or a missing python3.
    private func exitError() -> DBError {
        try? input?.close()
        task?.waitUntilExit()
        usleep(50000) // the last of stderr
        let tail = stderrTail()
        if task?.terminationStatus == 127 { return DBError(String(format: L("python3 wasn't found on the server. %@"), tail)) }
        return DBError(tail.isEmpty ? L("The connection to the server ended.") : tail)
    }

    // The next line of stdout without its newline, or nil at the end.
    private func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            // read(2), not FileHandle.read(upToCount:), which waits for the whole count instead of returning a line
            guard let fd = output?.fileDescriptor else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<n])
        }
    }

    // Sends one request and waits for the answer with its id (an "error" in the answer is the caller's business).
    // A helper that died while idle is started again first; one that dies during the request fails it.
    func send(_ request: [String: Any]) throws -> [String: Any] {
        guard started else { throw DBError(L("Not connected to the database.")) }
        if task?.isRunning != true { try start(path: path, readOnly: readOnly) }
        lastId += 1
        var message = request
        message["id"] = lastId
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        let written = (try? input?.write(contentsOf: data)) != nil
        guard written, let line = readLine() else {
            let ended = exitError()
            endProcess() // the next request starts it again
            throw DBError(String(format: L("Lost the connection to the server: %@"), ended.message))
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (answer["id"] as? NSNumber)?.intValue == lastId else {
            // never guess what an unexpected line means: drop the session
            endProcess()
            throw DBError(L("The server sent an unexpected answer, so the connection was closed."))
        }
        return answer
    }

    func stop() {
        started = false
        endProcess()
    }

    // Ends the process but not the connection: the next request starts a new one.
    private func endProcess() {
        guard let task else { return }
        self.task = nil
        try? input?.close() // the helper ends when its input does
        input = nil
        output = nil
        if task.isRunning {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if task.isRunning { task.terminate() }
            }
        }
    }
}
