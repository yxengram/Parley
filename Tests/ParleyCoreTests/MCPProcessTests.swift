import Darwin
import Foundation
import Testing
@testable import ParleyCore

// What is left running after a server stops. The grandchild (the mock's spawn_child) stands in for
// the `node` an `npx` leader starts: it does not watch its parent, so only the process group can
// stop it before its own 30 s are up.

@Suite(.serialized, .enabled(if: mcpPythonAvailable))
struct MCPProcessTests {
    /// Starts a server, has it start a grandchild, and returns both pids.
    private func startWithGrandchild(_ harness: MCPStdioHarness) async throws -> (leader: pid_t, grandchild: pid_t) {
        let result = try await harness.call("spawn_child")
        let grandchild = try #require(pid_t(result.text), "got \(result.text)")
        let leader = try #require(harness.pid)
        #expect(!processIsGone(grandchild))
        return (leader, grandchild)
    }

    @Test func theServerLeadsItsOwnProcessGroup() async throws {
        let harness = try MCPStdioHarness()
        defer { harness.finish() }
        _ = await harness.catalog()
        let pid = try #require(harness.pid)
        #expect(getpgid(pid) == pid)
        #expect(getpgid(pid) != getpgrp())
    }

    @Test func normalStop() async throws {
        let harness = try MCPStdioHarness()
        defer { harness.finish() }
        let (leader, grandchild) = try await startWithGrandchild(harness)
        await harness.manager.stop(serverID: harness.config.id)
        #expect(await eventually { processIsGone(leader) })
        #expect(await eventually { processIsGone(grandchild) })
    }

    @Test func aServerThatIgnoresEOF() async throws {
        let harness = try MCPStdioHarness(behaviors: ["ignore-eof"], grace: 0.2)
        defer { harness.finish() }
        let (leader, grandchild) = try await startWithGrandchild(harness)
        await harness.manager.stop(serverID: harness.config.id)
        #expect(await eventually { processIsGone(leader) })
        #expect(await eventually { processIsGone(grandchild) })
    }

    @Test func aServerThatIgnoresSIGTERM() async throws {
        let harness = try MCPStdioHarness(behaviors: ["ignore-sigterm"], grace: 0.2)
        defer { harness.finish() }
        let (leader, grandchild) = try await startWithGrandchild(harness)
        await harness.manager.stop(serverID: harness.config.id)
        #expect(await eventually { processIsGone(leader) })
        #expect(await eventually { processIsGone(grandchild) })
    }

    @Test func aLeaderThatExitsAndLeavesItsChildBehind() async throws {
        let harness = try MCPStdioHarness(behaviors: ["leader-exits-keeps-child"], grace: 0.2)
        defer { harness.finish() }
        let (leader, grandchild) = try await startWithGrandchild(harness)
        // Nobody asked it to stop: the crash path sweeps the group.
        #expect(await eventually(timeout: 8) { processIsGone(leader) })
        #expect(await eventually(timeout: 8) { processIsGone(grandchild) })
    }

    @Test func aCrashSweepsTheGroup() async throws {
        let harness = try MCPStdioHarness()
        defer { harness.finish() }
        let (leader, grandchild) = try await startWithGrandchild(harness)
        _ = try await harness.call("crash")
        #expect(await eventually(timeout: 8) { processIsGone(leader) })
        #expect(await eventually(timeout: 8) { processIsGone(grandchild) })
    }

    @Test func noZombieIsLeft() async throws {
        let exited = MCPFlag()
        let process = try MCPStdioProcess(executable: "/bin/sh", args: ["-c", "exit 0"], environment: ["PATH": "/usr/bin:/bin"], cwd: "/",
                                          log: MCPLogBuffer(), onLine: { _ in }, onExit: { _ in exited.set() }, onOversizedLine: {})
        #expect(await eventually { exited.isSet })
        // Reaped: the pid is gone altogether, not a zombie, which kill(0) still finds.
        #expect(await eventually { processIsGone(process.pid) })
    }

    @Test func shutdownSyncStopsStubbornServersInTime() async throws {
        let store = InMemoryMCPSecretStore()
        let manager = MCPConnectionManager(secrets: store, pathResolver: mcpTestResolver(), clientVersion: "t", stopGrace: 0.2)
        let scratch = try MCPScratch()
        var configs: [MCPServerConfig] = []
        for i in 0..<3 {
            let config = MCPServerConfig(name: "stubborn \(i)", command: mcpPython)
            try store.setSecrets(MCPServerSecrets(args: ["-I", mcpMockScript.path, "--behaviors", "ignore-sigterm", "--max-seconds", "30",
                                                         "--pid-file", scratch.path("pid\(i)")]), for: config.id)
            configs.append(config)
        }
        let catalog = await manager.catalog(for: configs)
        #expect(catalog.unavailable.isEmpty)
        let pids = (0..<3).compactMap { i in (try? String(contentsOfFile: scratch.path("pid\(i)"), encoding: .utf8)).flatMap { pid_t($0) } }
        #expect(pids.count == 3)

        let started = Date()
        manager.shutdownSync(grace: 0.2)
        #expect(Date().timeIntervalSince(started) < 2)
        for pid in pids {
            #expect(await eventually { processIsGone(pid) })
        }
    }

    @Test func shutdownSyncIsInstantWithNothingRunning() {
        let manager = MCPConnectionManager(secrets: InMemoryMCPSecretStore(), pathResolver: mcpTestResolver(), clientVersion: "t")
        let started = Date()
        manager.shutdownSync(grace: 0.4)
        #expect(Date().timeIntervalSince(started) < 0.1)
    }

    @Test func nothingStartsAfterShutdown() async throws {
        let harness = try MCPStdioHarness()
        harness.finish()
        let catalog = await harness.catalog()
        #expect(catalog.bindings.isEmpty)
        #expect(await eventually { harness.pid.map(processIsGone) ?? true })
    }
}
