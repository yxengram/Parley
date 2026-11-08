import AppKit
import SwiftUI
import ParleyCore

/// The window: the cardboard wall on the left, the room on the right. Custom on purpose:
/// no system split view or toolbar glass, so the whole window can be the hideout.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("hideout.sidebarWidth") private var sidebarWidth = 268.0
    @ViewState private var dragStartWidth: Double?

    private static let widthRange = 220.0...380.0

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 0) {
            if appState.isSidebarVisible {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                wallEdge
            }
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoomBackground())
                .sheet(item: $state.pendingLink) { link in
                    LinkConfirmationSheet(link: link, open: appState.confirmPendingLink) {
                        appState.pendingLink = nil
                    }
                    .hideoutSheet()
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Hideout.paper)
        .sheet(isPresented: $state.showNewChatSheet) {
            NewChatSheet()
                .environment(appState)
                .hideoutSheet()
        }
        // On the window, not the sidebar: hiding the wall must not lose a request or close a sheet.
        .modifier(ConversationDialogs())
        .alert(item: $state.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        // Every link click in this window ends here: nothing opens without LinkConfirmationSheet.
        .environment(\.openURL, OpenURLAction { url in
            appState.requestOpen(url) ? .handled : .discarded
        })
    }

    /// The dark seam where the wall meets the room; drag it to resize the wall.
    private var wallEdge: some View {
        Rectangle()
            .fill(Hideout.wallDeep)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: NSCursor.resizeLeftRight.set()
                        // Past the clamped width the pointer leaves the seam, mid-drag.
                        case .ended: if dragStartWidth == nil { NSCursor.arrow.set() }
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? sidebarWidth
                                dragStartWidth = start
                                sidebarWidth = min(max(start + value.translation.width, Self.widthRange.lowerBound),
                                                   Self.widthRange.upperBound)
                                NSCursor.resizeLeftRight.set()
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                NSCursor.arrow.set()
                            }
                    )
                    // Hiding the wall with the pointer on the seam ends no hover.
                    .onDisappear { NSCursor.arrow.set() }
            }
            .accessibilityHidden(true)
    }
}

/// A header for the room, same height and drag behaviour everywhere.
struct RoomHeader<Leading: View, Trailing: View>: View {
    @Environment(AppState.self) private var appState
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    static var height: CGFloat { 54 }

    var body: some View {
        HStack(spacing: 10) {
            if !appState.isSidebarVisible {
                // Clear of the traffic lights.
                Color.clear.frame(width: 72, height: 1)
                Button(action: appState.toggleSidebar) {
                    Label("Show Sidebar", systemImage: "sidebar.left")
                }
                .buttonStyle(RoundIconButtonStyle())
                .help("Show Sidebar (⌃⌘S)")
            }
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18)
        .frame(height: Self.height)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Line()
                .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [6, 5]))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

extension RoomHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.leading = leading()
        self.trailing = EmptyView()
    }
}

/// The detail column: chat, unlock prompt, loader or placeholder.
struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let id = appState.selection, let entry = appState.entry(id: id) {
            if let session = appState.session(for: id) {
                ChatView(session: session)
                    .id(session.id)
            } else if entry.isEncrypted {
                UnlockView(entry: entry)
                    .id(entry.id)
            } else {
                PlainLoaderView(entry: entry)
                    .id(entry.id)
            }
        } else {
            EmptyDetailView()
        }
    }
}

private struct PlainLoaderView: View {
    @Environment(AppState.self) private var appState
    let entry: LibraryEntry

    var body: some View {
        VStack(spacing: 0) {
            RoomHeader { Color.clear.frame(height: 1) }
            if let error = appState.loadErrors[entry.id] {
                ContentUnavailableView {
                    Label("Can't open conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        appState.loadErrors[entry.id] = nil
                        Task { await appState.loadPlain(entry) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry.id) {
            await appState.loadPlain(entry)
        }
    }
}

private struct EmptyDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let settings = appState.settings
        VStack(spacing: 0) {
            RoomHeader { Color.clear.frame(height: 1) }
            ScrollView {
                VStack(spacing: 14) {
                    TapedPicture(day: "fort-day", night: "fort-night", width: 340, aspect: 1.5)
                        .padding(.bottom, 12)
                    if settings.providers.isEmpty {
                        Text("Let's build the fort")
                            .lettered(30)
                        Text("Add an OpenAI-compatible server, such as LM Studio on this Mac or an API on your network, in Settings.")
                            .foregroundStyle(Hideout.inkSoft)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        HStack(spacing: 10) {
                            SettingsLink { Text("Open Settings…") }
                                .buttonStyle(TagButtonStyle(kind: .primary))
                            Button("New Chat") { appState.showNewChatSheet = true }
                                .buttonStyle(TagButtonStyle())
                        }
                        .padding(.top, 4)
                    } else {
                        Text("Nobody here but us")
                            .lettered(30)
                        Text("Pick a note from the wall, or start a new one.")
                            .foregroundStyle(Hideout.inkSoft)
                        Button("New Chat") { appState.showNewChatSheet = true }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(TagButtonStyle(kind: .primary))
                            .padding(.top, 4)
                        if let provider = settings.defaultProvider {
                            HStack(spacing: 4) {
                                Text("New chats use \(provider.name).")
                                SettingsLink {
                                    Text("Change in Settings…")
                                        .foregroundStyle(Hideout.emberText)
                                        .underline()
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.callout)
                            .foregroundStyle(Hideout.inkSoft)
                            .padding(.top, 6)
                        }
                    }
                    Label {
                        Text("Nothing leaves here except what you send to the servers you chose, the sign-in providers and the tools you allow.")
                    } icon: {
                        Image(systemName: "lock.fill").foregroundStyle(Hideout.brass)
                    }
                    .font(.footnote)
                    .foregroundStyle(Hideout.inkSoft)
                    .padding(.top, 18)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
