import AppKit
import SwiftUI
import ParleyCore

@main
struct ParleyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var appState: AppState { AppState.shared }

    var body: some Scene {
        WindowGroup("Parley") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    appState.showNewChatSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open Conversation File…") {
                    appState.openConversationFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Lock All Encrypted Conversations") {
                    appState.lockAll()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Never let window restoration persist anything (window titles can be
        // conversation titles, including of encrypted conversations).
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
