import SwiftUI
import ParleyCore

/// Shown when a locked, encrypted conversation is selected.
struct UnlockView: View {
    @Environment(AppState.self) private var appState
    let entry: LibraryEntry

    @ViewState private var password = ""
    @ViewState private var isWorking = false
    @ViewState private var error: String?
    @ViewState private var shakes: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RoomHeader {
                Text("Locked Conversation")
                    .font(Hideout.title(15))
                    .foregroundStyle(Hideout.ink)
                    .lineLimit(1)
            }
            // The door and its form are taller than a short window.
            GeometryReader { proxy in
                ScrollView {
                    door
                        .padding(.horizontal, 40)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Locked Conversation")
        .onAppear { focused = true }
    }

    private var door: some View {
        let folder = entry.url.deletingLastPathComponent()
        return VStack(spacing: 14) {
            TapedPicture(day: "door-day", night: "door-night", width: 220, aspect: 1)
                .padding(.bottom, 8)
            Text("Encrypted Conversation")
                .lettered(30)
                .foregroundStyle(Hideout.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Enter the password to decrypt it in memory.")
                .foregroundStyle(Hideout.inkSoft)
            HStack(spacing: 10) {
                // Drawn here, as the composer's is: AppKit's placeholder is a cold grey below 4.5:1.
                ZStack(alignment: .leading) {
                    if password.isEmpty {
                        Text("Password")
                            .foregroundStyle(Hideout.inkSoft)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    SecureField("Password", text: $password, prompt: Text(verbatim: ""))
                        .focused($focused)
                        .onSubmit(unlock)
                        .disabled(isWorking)
                }
                .paperField(fill: Hideout.tag, focused: focused, seed: 19)
                .frame(width: 260)
                .modifier(ShakeEffect(shakes: shakes))
                Button("Unlock", action: unlock)
                    .buttonStyle(TagButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
            .padding(.top, 4)
            ZStack {
                if isWorking {
                    HideoutSpinner()
                } else if let error {
                    Label(error, systemImage: "xmark.circle.fill")
                        .safetyNotice(.danger)
                }
            }
            .frame(maxWidth: 420, minHeight: 20)
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text("In “\(folder.lastPathComponent)” · modified \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                        .lineLimit(1)
                        .help(abbreviated(folder.path))
                    Button("Show in Finder") { appState.revealInFinder(entry) }
                        .buttonStyle(InlineLinkStyle())
                }
                .font(.caption)
                .foregroundStyle(Hideout.inkSoft)
                Text("Forgotten passwords can't be recovered.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Hideout.ink)
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        error = nil
        let pw = password
        Task {
            do {
                try await appState.unlock(entry, password: pw)
                password = ""
            } catch {
                self.error = error.localizedDescription
                password = ""
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            }
            isWorking = false
            // After re-enabling the field, so focus can land in it.
            if error != nil { focused = true }
        }
    }
}

/// A link in a line of text, in ember rather than the system's link blue.
private struct InlineLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Hideout.emberText)
            .underline()
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// Private on purpose: other surfaces define their own helpers, and these must not collide.
private enum SafetyTone { case caution, danger }

private extension View {
    /// A warning or an error on its own flat strip. Exact wording, no decoration.
    func safetyNotice(_ tone: SafetyTone) -> some View {
        let edge = tone == .danger ? Hideout.danger : Hideout.caution
        return self
            .font(.callout.weight(.medium))
            .foregroundStyle(edge)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .noticeCard(fill: tone == .danger ? Hideout.dangerWash : Hideout.cautionWash, edge: edge, radius: 8)
    }
}


private extension View {
    /// A text field on a paper tag; its edge shows where the typing goes.
    func paperField(fill: Color = Hideout.paperDeep, focused: Bool, seed: Int = 5) -> some View {
        self
            .textFieldStyle(.plain)
            .foregroundStyle(Hideout.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .paperCard(fill, seed: seed, radius: 9, shadow: false)
            .overlay {
                WobblyRect(seed: seed, radius: 9)
                    .strokeBorder(focused ? Hideout.ember : Hideout.line, lineWidth: focused ? 1.5 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
