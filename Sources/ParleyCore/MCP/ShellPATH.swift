import Darwin
import Foundation

// Finding a server's program. A Finder-launched app gets launchd's short PATH, so `npx` and `uvx`
// would not be found. The login shell knows the user's PATH: it is asked once, lazily, the first
// time a bare command starts, never at launch. Never `-i`: that sources .zshrc, whose plugins can
// make network calls or prompt.

public struct ResolvedCommand: Sendable, Equatable {
    public var executable: String
    /// PATH for the child.
    public var path: String

    public init(executable: String, path: String) {
        self.executable = executable
        self.path = path
    }
}

public final class ShellPATHResolver: @unchecked Sendable {
    private static let sentinel = "__PARLEY_PATH__"

    private let launchPATH: String?
    private let shell: String?
    private let home: String
    private let timeout: TimeInterval
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var search: Task<[String], Never>?

    public init(launchPATH: String? = ProcessInfo.processInfo.environment["PATH"],
                shell: String? = nil,            // nil: getpwuid(getuid()).pw_shell
                home: String = NSHomeDirectory(), timeout: TimeInterval = 5,
                log: (@Sendable (String) -> Void)? = nil) {
        self.launchPATH = launchPATH
        self.shell = shell
        self.home = home
        self.timeout = timeout
        self.log = log
    }

    /// The folders searched for a bare command: login-shell PATH, known folders, launchd PATH,
    /// without repeats. Once per instance; concurrent callers share the one run.
    public func searchPath() async -> [String] {
        await sharedSearch().value
    }

    private func sharedSearch() -> Task<[String], Never> {
        lock.lock(); defer { lock.unlock() }
        if let search { return search }
        let task = Task.detached { [self] in await runShellOnce() }
        search = task
        return task
    }

    private func runShellOnce() async -> [String] {
        let login = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: loginShellPATH())
            }
        }
        return Self.unique(login + knownDirectories() + launchEntries())
    }

    /// `overridePATH` (the server's own PATH): used as is, for lookup and for the child, and the
    /// shell does not run. An absolute command does not need the shell either; its own folder goes
    /// first on the child's PATH, so `#!/usr/bin/env node` works for nvm-style absolute paths.
    public func resolve(_ command: String, overridePATH: String?, relativeTo directory: String? = nil) async throws -> ResolvedCommand {
        var name = command
        if name == "~" || name.hasPrefix("~/") { name = home + name.dropFirst() }
        if name.contains("/") {
            if !name.hasPrefix("/") { name = (directory ?? home) + "/" + name }
            let folder = (name as NSString).deletingLastPathComponent
            guard Self.isExecutableFile(name) else {
                if !name.contains(" "), FileManager.default.fileExists(atPath: name) { throw MCPError.notExecutable(name) }
                throw MCPError.commandNotFound(name: command, searched: [folder])
            }
            if let overridePATH { return ResolvedCommand(executable: name, path: overridePATH) }
            let path = Self.unique([folder] + knownDirectories() + launchEntries())
            return ResolvedCommand(executable: name, path: path.joined(separator: ":"))
        }
        let folders: [String]
        if let overridePATH {
            folders = overridePATH.split(separator: ":").map(String.init)
        } else {
            folders = await searchPath()
        }
        for folder in folders where Self.isExecutableFile(folder + "/" + name) {
            return ResolvedCommand(executable: folder + "/" + name, path: overridePATH ?? folders.joined(separator: ":"))
        }
        throw MCPError.commandNotFound(name: command, searched: folders)
    }

    // MARK: Parts

    private func launchEntries() -> [String] {
        (launchPATH ?? "").split(separator: ":").map(String.init)
    }

    private func knownDirectories() -> [String] {
        var known = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/opt/local/bin"]
        known += ["/.local/bin", "/.cargo/bin", "/.bun/bin", "/.deno/bin", "/.volta/bin", "/.npm-global/bin",
                  "/.local/share/mise/shims", "/.asdf/shims"].map { home + $0 }
        // nvm set up only in .zshrc is out of the login shell's reach.
        let nvm = home + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        if let newest = versions.last { known.append(nvm + "/" + newest + "/bin") }
        return known
    }

    private func loginShell() -> String? {
        if let shell { return shell }
        guard let entry = getpwuid(getuid()), let shellPointer = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shellPointer)
        return path.isEmpty ? nil : path
    }

    /// Runs the login shell with a printf, in its own process group, with a small environment. A
    /// timeout or failure is logged, and the known folders still apply.
    private func loginShellPATH() -> [String] {
        guard let shell = loginShell() else { return [] }
        let script = #"printf "\n\#(Self.sentinel)%s\#(Self.sentinel)\n" "$PATH""#
        var environment = ["HOME": home, "TERM": "dumb", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell]
        for key in ["USER", "LOGNAME"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        let spawned: MCPSpawned
        do {
            spawned = try MCPSpawn.spawn(executable: shell, arguments: ["-l", "-c", script], environment: environment,
                                         directory: home, stdin: .null, captureStderr: false)
        } catch {
            log?("Could not run the login shell: \(error.localizedDescription)")
            return []
        }
        let pid = spawned.pid
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var timedOut = false
        while output.count < 1024 * 1024 {
            // Polled, because a daemon a profile left behind can hold the pipe open past everything.
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            var poller = pollfd(fd: spawned.stdoutRead, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 {
                timedOut = true
                break
            }
            let count = read(spawned.stdoutRead, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            output.append(contentsOf: chunk[0..<count])
            if Self.parse(output) != nil { break }
        }
        close(spawned.stdoutRead)
        killpg(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if timedOut {
            log?("The login shell did not answer within \(Int(timeout)) seconds.")
        }
        return Self.parse(output) ?? []
    }

    /// The PATH entries between the sentinels (profiles may print around them), absolute ones only.
    static func parse(_ output: Data) -> [String]? {
        let text = String(decoding: output, as: UTF8.self)
        guard let open = text.range(of: sentinel),
              let close = text.range(of: sentinel, range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    private static func unique(_ folders: [String]) -> [String] {
        var seen: Set<String> = []
        return folders.filter { seen.insert($0).inserted }
    }

    /// The child's base environment: not Parley's whole environment, so nothing in it reaches a
    /// server by accident. The server's own env goes on top of this.
    static func childEnvironment(path: String, server: [String: String],
                                 from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["HOME", "LOGNAME", "USER", "SHELL", "TERM", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = parent[key] { out[key] = value }
        }
        out["PATH"] = path
        out.merge(server) { _, new in new }
        return out
    }
}
