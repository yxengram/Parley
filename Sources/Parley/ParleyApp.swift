import AppKit
import SwiftUI
import ParleyCore

@main
struct ParleyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var appState: AppState { AppState.shared }

    init() {
        #if DEBUG
        // Must run before anything touches UserDefaults.standard or AppState.shared.
        SnapshotHarness.bootstrapIfNeeded()
        #endif
    }

    var body: some Scene {
        // A single main window: selection, sheets and alerts live on the shared AppState,
        // so a second window would mirror them.
        Window("Parley", id: "main") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Parley") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                FileCommands(appState: appState)
            }
            CommandGroup(after: .sidebar) {
                Button("Refresh Conversation List") { appState.reloadLibrary() }
                Divider()
            }
            ConversationCommands(appState: appState)
            MessageCommands(appState: appState)
            CommandGroup(replacing: .help) {
                HelpCommand()
            }
        }

        Window("Parley Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 620, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SnapshotHarness.isActive {
            SnapshotHarness.applicationWillFinishLaunching()
            return
        }
        #endif
        // Never let window restoration persist anything (window titles can be
        // conversation titles, including of encrypted conversations).
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SnapshotHarness.isActive {
            // Never activate or steal focus; the harness drives the UI and exits on its own.
            SnapshotHarness.applicationDidFinishLaunching()
            return
        }
        #endif
        // SwiftPM-built bundle: make sure we behave as a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                (note.object as? NSWindow)?.isRestorable = false
            }
        }
        for window in NSApp.windows {
            window.isRestorable = false
        }
        AppState.shared.reloadLibrary()
        // Safety net: make sure the main window is on screen after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !MainWindow.hasVisibleMainWindow { MainWindow.showViaMenu() }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock icon click with no window open: bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.showViaMenu() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = AppState.shared.saveAllBeforeQuit()
        guard result.count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = result.count == 1
            ? "A conversation could not be saved."
            : "\(result.count) conversations could not be saved."
        alert.informativeText = "Quitting now loses the changes that were not saved. \(result.firstError ?? "")"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.flushAllSync()
    }
}
