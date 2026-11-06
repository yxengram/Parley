import Darwin
import Foundation

// A local MCP server as a child process. posix_spawn rather than Foundation.Process, for two things
// Process does not promise: the child leads its own process group, so a server started through
// `npx` can be stopped with everything it started; and nothing of Parley's is inherited but the
// three pipes.

/// One spawned process: its pid and the parent's ends of its pipes (-1 when not a pipe).
struct MCPSpawned {
    var pid: pid_t
    var stdinWrite: Int32 = -1
    var stdoutRead: Int32 = -1
    var stderrRead: Int32 = -1
}

enum MCPSpawn {
    enum Input { case pipe, null }

    /// The child gets its own process group, default signal handling, an empty signal mask, and
    /// only stdin, stdout and stderr. stderr goes to /dev/null unless `captureStderr`.
    static func spawn(executable: String, arguments: [String], environment: [String: String], directory: String?,
                      stdin: Input, captureStderr: Bool) throws -> MCPSpawned {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        func closeAll() {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
        }
        func makePipe(_ fds: inout [Int32]) throws {
            guard pipe(&fds) == 0 else { throw MCPError.spawnFailed(String(cString: strerror(errno))) }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        }
        do {
            if case .pipe = stdin { try makePipe(&inPipe) }
            try makePipe(&outPipe)
            if captureStderr { try makePipe(&errPipe) }
        } catch {
            closeAll()
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if case .pipe = stdin {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        if captureStderr {
            posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        if let directory {
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&actions, directory)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, directory)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) }
        envp.append(nil)
        defer {
            for pointer in argv + envp { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        // The child's ends are the child's now.
        for fd in [inPipe[0], outPipe[1], errPipe[1]] where fd >= 0 { close(fd) }
        guard status == 0 else {
            for fd in [inPipe[1], outPipe[0], errPipe[0]] where fd >= 0 { close(fd) }
            throw MCPError.spawnFailed(String(cString: strerror(status)))
        }
        return MCPSpawned(pid: pid, stdinWrite: inPipe[1], stdoutRead: outPipe[0], stderrRead: errPipe[0])
    }

    /// True while any member of the group is alive. The leader is reaped by then, so a zombie
    /// cannot keep this true.
    static func groupIsAlive(_ pgid: pid_t) -> Bool {
        killpg(pgid, 0) == 0
    }
}

/// A server's stderr, for the log sheet: free-form text, in memory only. Lock-protected ring of
/// 2,000 lines or 256 KiB, each line capped at 4 KiB, decoded as lossy UTF-8.
public final class MCPLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var bytes = 0
    private var partial = Data()
    private let maxLines: Int
    private let maxBytes: Int
    private let maxLineBytes: Int

    public init(maxLines: Int = 2_000, maxBytes: Int = 256 * 1024, maxLineBytes: Int = 4 * 1024) {
        self.maxLines = maxLines
        self.maxBytes = maxBytes
        self.maxLineBytes = maxLineBytes
    }

    /// Raw bytes from a pipe; a line may arrive in pieces.
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        partial.append(data)
        var start = partial.startIndex
        while let newline = partial[start...].firstIndex(of: 0x0A) {
            store(partial[start..<newline])
            start = partial.index(after: newline)
        }
        partial = Data(partial[start...])
        if partial.count > maxLineBytes {
            store(partial)
            partial = Data()
        }
    }

    public func append(line: String) {
        lock.lock(); defer { lock.unlock() }
        store(Data(line.utf8))
    }

    private func store(_ raw: Data) {
        var data = raw
        if data.last == 0x0D { data.removeLast() }
        let line = String(decoding: data.prefix(maxLineBytes), as: UTF8.self)
        lines.append(line)
        bytes += line.utf8.count
        var drop = 0
        while drop < lines.count - 1, lines.count - drop > maxLines || bytes > maxBytes {
            bytes -= lines[drop].utf8.count
            drop += 1
        }
        if drop > 0 { lines.removeFirst(drop) }
    }

    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    public func tail(_ count: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(count))
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        lines.removeAll()
        partial = Data()
        bytes = 0
    }
}

final class MCPStdioProcess: @unchecked Sendable {
    let pid: pid_t

    private let log: MCPLogBuffer
    private let onLine: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let onOversizedLine: @Sendable () -> Void
    private let onOutputClosed: @Sendable () -> Void
    private let maxLineBytes: Int

    private let lock = NSCondition()
    private var stdinFD: Int32
    private var exitStatus: Int32?
    private var stdoutEnded = false
    private var reportedExit = false

    private let writeQueue = DispatchQueue(label: "local.parley.mcp.stdin")

    /// Spawns the process and starts reading. `onLine` gets each stdout line without its line end,
    /// on a thread of its own, in order.
    init(executable: String, args: [String], environment: [String: String], cwd: String, log: MCPLogBuffer,
         maxLineBytes: Int = MCPProtocol.maxMessageBytes,
         onLine: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void,
         onOversizedLine: @escaping @Sendable () -> Void,
         onOutputClosed: @escaping @Sendable () -> Void = {}) throws {
        let spawned = try MCPSpawn.spawn(executable: executable, arguments: args, environment: environment, directory: cwd,
                                         stdin: .pipe, captureStderr: true)
        pid = spawned.pid
        stdinFD = spawned.stdinWrite
        self.log = log
        self.onLine = onLine
        self.onExit = onExit
        self.onOversizedLine = onOversizedLine
        self.onOutputClosed = onOutputClosed
        self.maxLineBytes = maxLineBytes
        // Without this, writing to a dead child raises SIGPIPE and kills Parley. Non-blocking so
        // that closing stdin never has to wait for a write a stuck server does not drain.
        _ = fcntl(spawned.stdinWrite, F_SETNOSIGPIPE, 1)
        _ = fcntl(spawned.stdinWrite, F_SETFL, O_NONBLOCK)

        let stdoutFD = spawned.stdoutRead
        let stderrFD = spawned.stderrRead
        Self.thread("mcp stdout") { [self] in readStdout(stdoutFD) }
        Self.thread("mcp stderr") { [self] in readStderr(stderrFD) }
        // A blocking waitpid on this pid alone: other children (Foundation.Process in the app) stay
        // their owners' to reap, and a child that exits at once cannot be missed.
        Self.thread("mcp wait") { [self] in waitForExit() }
    }

    private static func thread(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.stackSize = 512 * 1024
        thread.start()
    }

    // MARK: Threads

    private func readStdout(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var line = Data()
        var discarding = false
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            var start = 0
            while start < count {
                let rest = chunk[start..<count]
                if let newline = rest.firstIndex(of: 0x0A) {
                    if !discarding {
                        line.append(contentsOf: chunk[start..<newline])
                        if line.last == 0x0D { line.removeLast() }
                        if !line.isEmpty { onLine(line) }
                    }
                    line = Data()
                    discarding = false
                    start = newline + 1
                } else {
                    if !discarding { line.append(contentsOf: rest) }
                    start = count
                }
                if line.count > maxLineBytes {
                    line = Data()
                    discarding = true
                    onOversizedLine()
                }
            }
        }
        close(fd)
        lock.lock()
        stdoutEnded = true
        lock.broadcast()
        // Closing its output is a server's way out (the spec's words), and one that stays running
        // can answer nothing more. The grace is for the exit status, which says more.
        let deadline = Date().addingTimeInterval(0.5)
        while exitStatus == nil, lock.wait(until: deadline) {}
        let running = exitStatus == nil
        lock.unlock()
        if running { onOutputClosed() }
    }

    private func readStderr(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            log.append(Data(chunk[0..<count]))
        }
        close(fd)
    }

    private func waitForExit() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result < 0 && errno == EINTR
        lock.lock()
        exitStatus = result == pid ? Self.decodedStatus(status) : -1
        lock.broadcast()
        // What the server wrote last may still be in the pipe. A grandchild holding stdout open
        // must not hold this back, though.
        let deadline = Date().addingTimeInterval(0.25)
        while !stdoutEnded, lock.wait(until: deadline) {}
        lock.unlock()
        reportExit()
    }

    private func reportExit() {
        lock.lock()
        let first = !reportedExit
        reportedExit = true
        let status = exitStatus ?? -1
        lock.unlock()
        if first { onExit(status) }
    }

    /// The exit status, or 128 + the signal, as a shell shows it.
    private static func decodedStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    // MARK: Writing

    /// Queues one line (the newline is added here). A write to a process that closed its stdin
    /// means the server is gone.
    func write(_ line: Data) {
        var bytes = line
        bytes.append(0x0A)
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count {
                lock.lock()
                let fd = stdinFD
                guard fd >= 0 else {
                    lock.unlock()
                    return
                }
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
                let failure = errno
                lock.unlock()
                if written > 0 {
                    offset += written
                } else if failure == EAGAIN {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 50)
                } else if failure != EINTR {
                    reportExit()
                    return
                }
            }
        }
    }

    private func closeStdin() {
        lock.lock()
        let fd = stdinFD
        stdinFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: Stopping

    private func waitForLeader(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while exitStatus == nil {
            if !lock.wait(until: deadline) { break }
        }
        return exitStatus != nil
    }

    private func waitForGroup(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while MCPSpawn.groupIsAlive(pid) {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }

    /// The spec's shutdown: close stdin, wait, SIGTERM, wait, SIGKILL, then the same for whatever
    /// else is left in the group (a crash takes this path too, so an `npx` leader dying does not
    /// leave `node` behind). Blocking: call it off the main actor, except at quit. Safe to call
    /// more than once and from several threads.
    func terminate(grace: TimeInterval) {
        closeStdin()
        if !waitForLeader(grace) {
            killpg(pid, SIGTERM)
            if !waitForLeader(grace) {
                killpg(pid, SIGKILL)
                _ = waitForLeader(1)
            }
        }
        guard MCPSpawn.groupIsAlive(pid) else { return }
        killpg(pid, SIGTERM)
        if !waitForGroup(grace) {
            killpg(pid, SIGKILL)
            _ = waitForGroup(1)
        }
    }
}

/// What must end when Parley quits. An instance owned by the manager, and lock-protected: quit
/// cannot await an actor.
protocol MCPStoppable: AnyObject, Sendable {
    func stopNow(grace: TimeInterval)
}

final class MCPProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ObjectIdentifier: MCPStoppable] = [:]
    private var isClosed = false

    /// False once shut down: the caller must stop `item` itself.
    func add(_ item: MCPStoppable) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return false }
        items[ObjectIdentifier(item)] = item
        return true
    }

    func remove(_ item: MCPStoppable) {
        lock.lock(); defer { lock.unlock() }
        items[ObjectIdentifier(item)] = nil
    }

    /// Stops everything at once and refuses new entries. Returns when all have ended.
    func shutdown(grace: TimeInterval) {
        lock.lock()
        isClosed = true
        let all = Array(items.values)
        items.removeAll()
        lock.unlock()
        guard !all.isEmpty else { return }
        let group = DispatchGroup()
        for item in all {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                item.stopNow(grace: grace)
                group.leave()
            }
        }
        group.wait()
    }
}
