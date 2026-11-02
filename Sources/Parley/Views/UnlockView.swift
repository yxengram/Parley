import SwiftUI
import ParleyCore

/// Shown when a locked, encrypted conversation is selected.
struct UnlockView: View {
    @Environment(AppState.self) private var appState
    let entry: LibraryEntry

    @ViewState private var password = ""
    @ViewState private var isWorking = false
    @ViewState private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Encrypted conversation")
                .font(.title2.weight(.semibold))
            Text("Enter the password to decrypt it in memory.")
                .foregroundStyle(.secondary)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .focused($focused)
                    .onSubmit(unlock)
                    .disabled(isWorking)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Text(entry.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                focused = true
            }
            isWorking = false
        }
    }
}
