import SwiftUI
import ParleyCore

/// Password + confirmation fields, shared by the new-chat and encrypt sheets.
struct PasswordFields: View {
    @Binding var password: String
    @Binding var confirm: String

    private enum Field { case password, confirm }
    @FocusState private var focus: Field?

    var body: some View {
        // The field carries the label for VoiceOver; the visible one would repeat it.
        LabeledContent {
            SecureField("Password", text: $password, prompt: Text(verbatim: ""))
                .textContentType(.newPassword)
                .labelsHidden()
                .focused($focus, equals: .password)
                .paperField(focused: focus == .password, seed: 5)
        } label: {
            Text("Password").accessibilityHidden(true)
        }
        .labeledContentStyle(PaperRowStyle())
        LabeledContent {
            SecureField("Confirm password", text: $confirm, prompt: Text(verbatim: ""))
                .textContentType(.newPassword)
                .labelsHidden()
                .focused($focus, equals: .confirm)
                .paperField(focused: focus == .confirm, seed: 6)
        } label: {
            Text("Confirm password").accessibilityHidden(true)
        }
        .labeledContentStyle(PaperRowStyle())
        if let hint = Self.hint(password: password, confirm: confirm) {
            Text(hint)
                .font(.callout)
                .foregroundStyle(!confirm.isEmpty && password != confirm ? Hideout.danger : Hideout.inkSoft)
        }
        Label("If you forget this password, the conversation can't be recovered.", systemImage: "exclamationmark.triangle.fill")
            .safetyNotice(.caution)
    }

    static func isValid(password: String, confirm: String) -> Bool {
        !password.isEmpty && password == confirm
    }

    static func hint(password: String, confirm: String) -> String? {
        if !confirm.isEmpty && password != confirm { return String(localized: "Passwords don't match.") }
        if !password.isEmpty && password.count < 8 { return String(localized: "Short passwords are easy to guess. Use at least 8 characters.") }
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
                .lettered(26)
                .foregroundStyle(Hideout.ink)
                .accessibilityAddTraits(.isHeader)
            Text(target.mode == .encrypt
                 ? "The file will be encrypted with AES-256-GCM using a key derived from this password. It is decrypted only in memory."
                 : "The file will be re-encrypted with a key derived from the new password.")
                .font(.callout)
                .foregroundStyle(Hideout.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                PasswordFields(password: $password, confirm: $confirm)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stitchedCard(seed: 21)
            if let error {
                Text(error)
                    .safetyNotice(.danger)
            }
            HStack(spacing: 8) {
                if isWorking { HideoutSpinner() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(TagButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(target.mode == .encrypt ? "Encrypt" : "Change Password", action: submit)
                    .buttonStyle(TagButtonStyle(kind: .primary))
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


/// A label beside its field, for a stitched card.
private struct PaperRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .frame(width: 120, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
