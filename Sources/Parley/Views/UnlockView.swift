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
        let folder = entry.url.deletingLastPathComponent()
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Encrypted Conversation")
                .font(.title2.weight(.semibold))
            Text("Enter the password to decrypt it in memory.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .focused($focused)
                    .onSubmit(unlock)
                    .disabled(isWorking)
                    .modifier(ShakeEffect(shakes: shakes))
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
            .controlSize(.large)
            .padding(.top, 4)
            ZStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else if let error {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .frame(minHeight: 20)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("In “\(folder.lastPathComponent)” · modified \(entry.updatedAt.formatted(.relative(presentation: .named)))")
                        .lineLimit(1)
                        .help(abbreviated(folder.path))
                    Button("Show in Finder") { appState.revealInFinder(entry) }
                        .buttonStyle(.link)
                }
                Text("Forgotten passwords can't be recovered.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Locked Conversation")
        .onAppear { focused = true }
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
