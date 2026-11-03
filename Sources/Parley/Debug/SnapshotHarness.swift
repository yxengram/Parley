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

    nonisolated static let outputDirectoryPath: String? = {
        let value = ProcessInfo.processInfo.environment["PARLEY_SNAPSHOT_DIR"] ?? ""
        return value.isEmpty ? nil : value
    }()

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

    /// Read by MessageRow: shows the hover action bar for this message without a mouse.
    static var forcedHoverMessageID: UUID?

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
    }

    /// Holds the redirected standard defaults for the swizzled `+standardUserDefaults`.
    private final class StandardDefaultsBox: @unchecked Sendable {
        nonisolated(unsafe) static var suite: UserDefaults?
    }

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
        DispatchQueue.global().asyncAfter(deadline: .now() + 85) {
            FileHandle.standardError.write(Data("[snapshot] watchdog: giving up after 85 s\n".utf8))
            try? FileManager.default.removeItem(atPath: rootPath)
            exit(3)
        }
        log("bootstrap: tmp=\(tmp.path) bundle=\(Bundle.main.bundleIdentifier ?? "nil") mock=\(mockURL ?? "none")")
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
        settings.defaultProviderID = p.id
        settings.defaultDirectoryPath = defaultDirectory.path
        // The main sample chat's model is not on the mock server: its limit is the user's own value.
        settings.setManualContextLength(32768, providerID: p.id, model: "qwen3-14b-instruct")
        do {
            try seed()
        } catch {
            log("seed failed: \(error)")
        }
        return settings
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

    private static func run() async {
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

            // 4. Per-conversation settings popover.
            await capturePopover(appearance)

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

    private static func capturePopover(_ appearance: String) async {
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
                capture(appearance, "conversation-settings-popover", overlays: [(popoverView, origin)])
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
        capture(appearance, "conversation-settings-popover", overlays: [(host, origin)])
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
        let tabNames = ["providers", "general"]
        if let tabs = window.contentViewController as? NSTabViewController {
            for (i, name) in tabNames.enumerated() where i < tabs.tabViewItems.count {
                tabs.selectedTabViewItemIndex = i
                await wait(0.6)
                capture(appearance, "settings-\(name)", window: window)
            }
        } else if let toolbar = window.toolbar, !toolbar.items.isEmpty {
            log("settings: no NSTabViewController (\(String(describing: window.contentViewController))); using the toolbar")
            for (i, name) in tabNames.enumerated() where i < toolbar.items.count {
                let item = toolbar.items[i]
                toolbar.selectedItemIdentifier = item.itemIdentifier
                if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                await wait(0.6)
                capture(appearance, "settings-\(name)", window: window)
            }
        } else {
            log("settings: no tab controller and no toolbar; capturing the current tab only")
            capture(appearance, "settings", window: window)
        }
        window.close()
        await wait(0.4)
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
