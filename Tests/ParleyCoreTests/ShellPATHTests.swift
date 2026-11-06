import Darwin
import Foundation
import Testing
@testable import ParleyCore

// Finding a server's program. Every test uses a fake login shell and a temporary home: the real
// shell and its profile are never run.

private func writeScript(_ path: String, _ body: String) throws {
    try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
}

/// A shell that logs its arguments, prints a banner and then the sentinels.
private func fakeShell(_ scratch: MCPScratch, path: String, banner: String = "Welcome to the profile\n") throws -> String {
    let shell = scratch.path("fake-shell")
    try writeScript(shell, """
    echo run >> "\(scratch.path("runs"))"
    echo "$@" >> "\(scratch.path("args"))"
    printf '\(banner)'
    PATH='\(path)' /bin/sh -c "$3"
    printf 'after the sentinels\\n'
    """)
    return shell
}

private func runs(_ scratch: MCPScratch) -> Int {
    ((try? String(contentsOfFile: scratch.path("runs"), encoding: .utf8)) ?? "").split(separator: "\n").count
}

@Suite struct ShellPATHTests {
    @Test func aCommandOnlyOnTheLoginPATHResolves() async throws {
        let scratch = try MCPScratch()
        let bin = scratch.path("login-bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try writeScript(bin + "/only-here", "exit 0")
        // The Finder case: launchd's short PATH does not have it.
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin:/bin", shell: try fakeShell(scratch, path: bin + ":relative/ignored"), home: scratch.url.path)
        let resolved = try await resolver.resolve("only-here", overridePATH: nil)
        #expect(resolved.executable == bin + "/only-here")
        #expect(resolved.path.hasPrefix(bin + ":"))
        #expect(resolved.path.contains("/opt/homebrew/bin"))
        #expect(resolved.path.hasSuffix("/usr/bin:/bin"))
        #expect(!resolved.path.contains("relative/ignored"))
    }

    @Test func theResolvedCommandReallyRuns() async throws {
        let scratch = try MCPScratch()
        let bin = scratch.path("login-bin")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try writeScript(bin + "/say", #"echo "$PATH""#)
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin:/bin", shell: try fakeShell(scratch, path: bin), home: scratch.url.path)
        let resolved = try await resolver.resolve("say", overridePATH: nil)
        let spawned = try MCPSpawn.spawn(executable: resolved.executable, arguments: [],
                                         environment: ShellPATHResolver.childEnvironment(path: resolved.path, server: [:]),
                                         directory: scratch.url.path, stdin: .null, captureStderr: false)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(spawned.stdoutRead, &chunk, chunk.count)
            if count <= 0 { break }
            output.append(contentsOf: chunk[0..<count])
        }
        close(spawned.stdoutRead)
        var status: Int32 = 0
        waitpid(spawned.pid, &status, 0)
        #expect(String(decoding: output, as: UTF8.self).hasPrefix(bin))
    }

    @Test func neverInteractive() async throws {
        let scratch = try MCPScratch()
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: try fakeShell(scratch, path: "/bin"), home: scratch.url.path)
        _ = await resolver.searchPath()
        let arguments = try String(contentsOfFile: scratch.path("args"), encoding: .utf8)
        #expect(arguments.hasPrefix("-l -c "))
        #expect(!arguments.split(separator: " ").contains("-i"))
    }

    @Test func runsOnceAcrossConcurrentCallers() async throws {
        let scratch = try MCPScratch()
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: try fakeShell(scratch, path: "/bin"), home: scratch.url.path)
        await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 { group.addTask { await resolver.searchPath() } }
            for await _ in group {}
        }
        #expect(runs(scratch) == 1)
    }

    @Test func twoResolversShareNothing() async throws {
        let scratch = try MCPScratch()
        let shell = try fakeShell(scratch, path: "/bin")
        _ = await ShellPATHResolver(launchPATH: "/usr/bin", shell: shell, home: scratch.url.path).searchPath()
        _ = await ShellPATHResolver(launchPATH: "/usr/bin", shell: shell, home: scratch.url.path).searchPath()
        #expect(runs(scratch) == 2)
    }

    @Test func anAbsoluteCommandRunsNoShell() async throws {
        let scratch = try MCPScratch()
        let tool = scratch.path("nvm-node/bin")
        try FileManager.default.createDirectory(atPath: tool, withIntermediateDirectories: true)
        try writeScript(tool + "/server", "exit 0")
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: try fakeShell(scratch, path: "/bin"), home: scratch.url.path)
        let resolved = try await resolver.resolve(tool + "/server", overridePATH: nil)
        #expect(resolved.executable == tool + "/server")
        #expect(resolved.path.hasPrefix(tool + ":"))
        #expect(runs(scratch) == 0)
    }

    @Test func pathInTheServersEnvironmentSkipsTheShell() async throws {
        let scratch = try MCPScratch()
        let bin = scratch.path("mine")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try writeScript(bin + "/tool", "exit 0")
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: try fakeShell(scratch, path: "/bin"), home: scratch.url.path)
        let resolved = try await resolver.resolve("tool", overridePATH: bin)
        #expect(resolved == ResolvedCommand(executable: bin + "/tool", path: bin))
        #expect(runs(scratch) == 0)
    }

    @Test func aHomeRelativeCommand() async throws {
        let scratch = try MCPScratch()
        try writeScript(scratch.path("tool"), "exit 0")
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: "/usr/bin/true", home: scratch.url.path)
        #expect(try await resolver.resolve("~/tool", overridePATH: nil).executable == scratch.path("tool"))
        #expect(try await resolver.resolve("./tool", overridePATH: nil, relativeTo: scratch.url.path).executable == scratch.url.path + "/./tool")
    }

    @Test func notFoundSaysWhereItLooked() async throws {
        let scratch = try MCPScratch()
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: "/usr/bin/true", home: scratch.url.path)
        do {
            _ = try await resolver.resolve("no-such-program-anywhere", overridePATH: nil)
            Issue.record("expected commandNotFound")
        } catch let error as MCPError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("no-such-program-anywhere"))
            #expect(text.contains("/opt/homebrew/bin"))
            #expect(text.contains("Use an absolute path, or set PATH in this server's environment."))
        }
    }

    @Test func aDirectoryOrPlainFileIsNotACommand() async throws {
        let scratch = try MCPScratch()
        try FileManager.default.createDirectory(atPath: scratch.path("dir"), withIntermediateDirectories: true)
        try "x".write(toFile: scratch.path("plain"), atomically: true, encoding: .utf8)
        let resolver = ShellPATHResolver(launchPATH: nil, shell: "/usr/bin/true", home: scratch.url.path)
        await #expect(throws: MCPError.self) { try await resolver.resolve(scratch.path("dir"), overridePATH: nil) }
        await #expect(throws: MCPError.self) { try await resolver.resolve(scratch.path("plain"), overridePATH: nil) }
    }

    @Test func aHangingShellIsKilledAndKnownFoldersStillApply() async throws {
        let scratch = try MCPScratch()
        let shell = scratch.path("hanging")
        try writeScript(shell, """
        [ "$1" = warm ] && exit 0
        echo $$ > "\(scratch.path("shell-pid"))"
        sleep 30 &
        echo $! > "\(scratch.path("child-pid"))"
        wait
        """)
        // macOS checks a new script on its first run, which can take longer than this timeout.
        let warm = try Process.run(URL(fileURLWithPath: shell), arguments: ["warm"])
        warm.waitUntilExit()
        let messages = MCPLogBuffer()
        let resolver = ShellPATHResolver(launchPATH: "/usr/bin", shell: shell, home: scratch.url.path, timeout: 1.5,
                                         log: { messages.append(line: $0) })
        let started = Date()
        let path = await resolver.searchPath()
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/bin"))
        #expect(messages.snapshot().contains { $0.contains("did not answer") })
        let child = pid_t(try String(contentsOfFile: scratch.path("child-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(await eventually { child.map(processIsGone) ?? false })
    }

    @Test func aFailingShellLeavesTheKnownFolders() async throws {
        let scratch = try MCPScratch()
        let shell = scratch.path("failing")
        try writeScript(shell, "exit 7")
        let path = await ShellPATHResolver(launchPATH: "/usr/bin", shell: shell, home: scratch.url.path).searchPath()
        #expect(path.contains("/usr/local/bin"))
    }

    @Test func nvmsNewestVersionIsKnown() async throws {
        let scratch = try MCPScratch()
        for version in ["v9.1.0", "v20.11.1", "v18.0.0"] {
            try FileManager.default.createDirectory(atPath: scratch.path(".nvm/versions/node/\(version)/bin"), withIntermediateDirectories: true)
        }
        let path = await ShellPATHResolver(launchPATH: nil, shell: "/usr/bin/true", home: scratch.url.path).searchPath()
        #expect(path.contains(scratch.path(".nvm/versions/node/v20.11.1/bin")))
        #expect(!path.contains(scratch.path(".nvm/versions/node/v9.1.0/bin")))
    }

    @Test func parsingSentinels() {
        #expect(ShellPATHResolver.parse(Data("noise\n__PARLEY_PATH__/a:/b:rel__PARLEY_PATH__\nmore".utf8)) == ["/a", "/b"])
        #expect(ShellPATHResolver.parse(Data("no sentinels".utf8)) == nil)
    }

    @Test func childEnvironmentIsNotOurs() {
        let parent = ["HOME": "/h", "USER": "u", "API_TOKEN": "fake", "DYLD_INSERT_LIBRARIES": "x"]
        let env = ShellPATHResolver.childEnvironment(path: "/bin", server: ["MINE": "1", "USER": "other"], from: parent)
        #expect(env == ["HOME": "/h", "USER": "other", "PATH": "/bin", "MINE": "1"])
    }
}
