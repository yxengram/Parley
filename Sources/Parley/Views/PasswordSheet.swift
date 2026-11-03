import SwiftUI
import ParleyCore

/// Password + confirmation fields, shared by the new-chat and encrypt sheets.
struct PasswordFields: View {
    @Binding var password: String
    @Binding var confirm: String

    var body: some View {
        SecureField("Password", text: $password)
            .textContentType(.newPassword)
        SecureField("Confirm password", text: $confirm)
            .textContentType(.newPassword)
        if let hint = Self.hint(password: password, confirm: confirm) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(!confirm.isEmpty && password != confirm ? Color.red : Color.secondary)
        }
        Label("If you forget this password, the conversation can't be recovered.", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func isValid(password: String, confirm: String) -> Bool {
        !password.isEmpty && password == confirm
    }

    static func hint(password: String, confirm: String) -> String? {
        if !confirm.isEmpty && password != confirm { return "Passwords don't match." }
        if !password.isEmpty && password.count < 8 { return "Short passwords are easy to guess. Use at least 8 characters." }
        return nil
    }
}

/// Encrypt an existing conversation, or change its password.
struct PasswordSheet: View {
    struct Target: Identifiable {
        enum Mode { case encrypt, change }
        let session: ConversationSession
        let mode: Mode
        var id: UUID { session.id }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let target: Target
    /// Called after a successful change; `true` when a plain file was newly encrypted.
    var onSuccess: (Bool) -> Void = { _ in }

    @ViewState private var password = ""
    @ViewState private var confirm = ""
    @ViewState private var isWorking = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.mode == .encrypt ? "Encrypt Conversation" : "Change Password")
                .font(.headline)
            Text(target.mode == .encrypt
                 ? "The file will be encrypted with AES-256-GCM using a key derived from this password. It is decrypted only in memory."
                 : "The file will be re-encrypted with a key derived from the new password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section {
                    PasswordFields(password: $password, confirm: $confirm)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, -20)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(target.mode == .encrypt ? "Encrypt" : "Change Password", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !PasswordFields.isValid(password: password, confirm: confirm))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        guard PasswordFields.isValid(password: password, confirm: confirm) else { return }
        isWorking = true
        error = nil
        let pw = password
        Task {
            do {
                let newlyEncrypted = try await appState.setPassword(for: target.session, password: pw)
                onSuccess(newlyEncrypted)
                password = ""
                confirm = ""
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}
