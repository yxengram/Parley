import Foundation

/// JSON-RPC over a child's stdin and stdout, one message per line.
final class MCPStdioTransport: MCPTransport, MCPStoppable, @unchecked Sendable {
    struct Launch: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var directory: String
    }

    let isHTTP = false
    private let launch: Launch
    private let log: MCPLogBuffer
    private let registry: MCPProcessRegistry?
    private let maxMessageBytes: Int

    private let lock = NSLock()
    private var inboundHandler: (@Sendable (MCPInbound) -> Void)?
    private var closedHandler: (@Sendable (Error?) -> Void)?
    private var process: MCPStdioProcess?
    private var pending: [Int: CheckedContinuation<MCPResponse, Error>] = [:]
    private var ended: Error?
    private var closing = false

    init(launch: Launch, log: MCPLogBuffer, registry: MCPProcessRegistry?, maxMessageBytes: Int = MCPProtocol.maxMessageBytes) {
        self.launch = launch
        self.log = log
        self.registry = registry
        self.maxMessageBytes = maxMessageBytes
    }

    var onInbound: (@Sendable (MCPInbound) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return inboundHandler }
        set { lock.lock(); defer { lock.unlock() }; inboundHandler = newValue }
    }

    var onClosed: (@Sendable (Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closedHandler }
        set { lock.lock(); defer { lock.unlock() }; closedHandler = newValue }
    }

    func start() async throws {
        let log = self.log
        let process = try MCPStdioProcess(
            executable: launch.executable, args: launch.arguments, environment: launch.environment,
            cwd: launch.directory, log: log, maxLineBytes: maxMessageBytes,
            onLine: { [weak self] line in self?.received(line) },
            onExit: { [weak self] status in self?.processEnded(status: status) },
            onOversizedLine: { [weak self] in self?.endConnection(MCPError.messageTooLarge) },
            onOutputClosed: { [weak self] in self?.endConnection(MCPError.streamEnded) })
        let alreadyEnded = lock.withLock {
            self.process = process
            return ended != nil
        }
        if let registry, !registry.add(self) {
            // The app is quitting.
            process.terminate(grace: 0)
            throw MCPError.streamEnded
        }
        // It exited before `process` was set, so nobody has swept its group.
        if alreadyEnded { clearProcessGroup(process) }
    }

    func send(_ message: MCPOutbound) async throws -> MCPResponse {
        guard let id = message.id else { throw MCPError.invalidResponse("a request needs an id") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let ended {
                    lock.unlock()
                    continuation.resume(throwing: ended)
                    return
                }
                pending[id] = continuation
                let process = self.process
                lock.unlock()
                // The handler below may have run before the entry existed.
                if Task.isCancelled {
                    finish(id, with: .failure(CancellationError()))
                } else {
                    process?.write(MCPWire.encode(message))
                }
            }
        } onCancel: {
            finish(id, with: .failure(CancellationError()))
        }
    }

    private func finish(_ id: Int, with result: Result<MCPResponse, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    func notify(_ message: MCPOutbound) async throws {
        writeIfOpen(MCPWire.encode(message))
    }

    func respond(to id: JSONValue, result: JSONValue?, error: MCPRPCError?, headers: [String: String]) async throws {
        writeIfOpen(MCPWire.encodeResponse(id: id, result: result, error: error))
    }

    private func writeIfOpen(_ line: Data) {
        lock.lock()
        let process = ended == nil ? self.process : nil
        lock.unlock()
        process?.write(line)
    }

    func resetSession() {}

    private func received(_ line: Data) {
        guard let messages = MCPWire.decode(line) else {
            if JSONValue.isOutOfRange(line) {
                // It may be the answer someone waits for, and its id cannot be read.
                endConnection(MCPError.invalidResponse("a message is nested too deeply or has a number out of range"))
                return
            }
            // The spec forbids it, but libraries print to stdout. Not worth losing the server over.
            log.append(line: "[stdout, ignored] " + String(decoding: line.prefix(200), as: UTF8.self))
            return
        }
        for message in messages {
            if case .response(let id, let result, let error) = message {
                // A response to something given up on goes nowhere.
                if let number = id.intValue {
                    finish(Int(number), with: .success(MCPResponse(result: result, error: error)))
                } else if error != nil, let waiting = onlyPending() {
                    // A rejection the server could not tie to a request, with one to tie it to.
                    finish(waiting, with: .success(MCPResponse(result: result, error: error)))
                }
            } else {
                onInbound?(message)
            }
        }
    }

    private func onlyPending() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return pending.count == 1 ? pending.keys.first : nil
    }

    private func processEnded(status: Int32) {
        endConnection(MCPError.exited(status: status, stderrTail: log.tail(5)))
    }

    /// Fails what is waiting, tells the owner, and clears away what is left of the process group.
    private func endConnection(_ error: Error) {
        lock.lock()
        if ended == nil { ended = error }
        let reason = ended
        let waiting = pending
        pending = [:]
        let process = self.process
        let handler = closing ? nil : closedHandler
        let sweeps = !closing
        closedHandler = nil
        lock.unlock()
        for continuation in waiting.values { continuation.resume(throwing: reason ?? MCPError.streamEnded) }
        handler?(reason)
        if sweeps, let process { clearProcessGroup(process) }
    }

    private func clearProcessGroup(_ process: MCPStdioProcess) {
        DispatchQueue.global(qos: .utility).async { [self] in
            process.terminate(grace: 2)
            registry?.remove(self)
        }
    }

    func close(grace: TimeInterval) async {
        lock.withLock { closing = true }
        endConnection(MCPError.streamEnded)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                stopNow(grace: grace)
                continuation.resume()
            }
        }
    }

    func stopNow(grace: TimeInterval) {
        lock.lock()
        closing = true
        let process = self.process
        lock.unlock()
        process?.terminate(grace: grace)
        registry?.remove(self)
    }
}
