import AppKit
import ParleyCore
import SwiftUI

// Sign-in for one HTTP server. Opening this section reads the stored sign-in and nothing else. Only the
// Sign In button contacts anything, and the sheet names every new host before it is contacted.

@MainActor
@Observable
final class MCPSignInModel {
    private(set) var review: MCPOAuthReview?
    private(set) var isRunning = false
    private(set) var info: MCPSignInInfo?
    var message: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: CheckedContinuation<MCPOAuthAnswer, Never>?

    func load(_ appState: AppState, serverID: UUID) async {
        info = await appState.signInInfo(serverID)
    }

    func signIn(_ appState: AppState, serverID: UUID) {
        guard !isRunning else { return }
        isRunning = true
        message = nil
        task = Task { [weak self] in
            do {
                try await appState.signIn(serverID) { review in
                    await self?.ask(review) ?? .cancel
                }
                self?.message = nil
            } catch MCPError.oauth(.cancelled) {
                self?.message = nil
            } catch {
                self?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.isRunning = false
            await self?.load(appState, serverID: serverID)
        }
    }

    func signOut(_ appState: AppState, serverID: UUID) {
        Task { [weak self] in
            do {
                try await appState.signOut(serverID)
                self?.message = nil
            } catch {
                self?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await self?.load(appState, serverID: serverID)
        }
    }

    /// Ends when the flow is cancelled too: the view asking may be gone, and then nothing would ever
    /// answer.
    private func ask(_ review: MCPOAuthReview) async -> MCPOAuthAnswer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending?.resume(returning: .cancel)
                pending = nil
                if Task.isCancelled {
                    continuation.resume(returning: .cancel)
                } else {
                    pending = continuation
                    self.review = review
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(.cancel) }
        }
    }

    func answer(_ answer: MCPOAuthAnswer) {
        review = nil
        pending?.resume(returning: answer)
        pending = nil
    }

    /// Cancel, and leaving this server: nothing waits in the background for a page nobody watches.
    func cancel() {
        answer(.cancel)
        task?.cancel()
    }
}

struct MCPSignInSection: View {
    @Environment(AppState.self) private var appState
    let serverID: UUID
    @Binding var draft: MCPServerDraft
    let needsAttention: MCPSignInNeed
    /// Saves the form first, as Connect does. False: it could not be saved.
    let prepare: () -> Bool

    @ViewState private var model = MCPSignInModel()

    private var hasStaticAuthorization: Bool {
        draft.headers.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "authorization" }
    }

    private var callbackAddress: String {
        let port = draft.oauthCallbackPort.trimmingCharacters(in: .whitespacesAndNewlines)
        return "http://127.0.0.1:\(port.isEmpty ? "<port>" : port)/callback"
    }

    var body: some View {
        Section {
            if hasStaticAuthorization {
                Text("This server has a static Authorization header, so it does not use sign-in.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
            } else {
                if let info = model.info {
                    LabeledContent("Signed in through") { Text(verbatim: ToolDisplay.address(info.provider)) }
                    if !info.scopes.isEmpty {
                        LabeledContent("Permissions") {
                            Text(verbatim: ToolDisplay.line(info.scopes.joined(separator: " ")))
                                .textSelection(.enabled)
                        }
                    }
                }
                if let note = attentionText {
                    Text(verbatim: note)
                        .safetyNotice(.caution)
                }
                HStack {
                    Button(model.isRunning ? "Signing In…" : "Sign In") {
                        if prepare() { model.signIn(appState, serverID: serverID) }
                    }
                    .buttonStyle(TagButtonStyle())
                    .disabled(model.isRunning)
                    if model.isRunning {
                        Button("Cancel") { model.cancel() }
                            .buttonStyle(TagButtonStyle())
                    }
                    if model.info != nil, !model.isRunning {
                        Button("Sign Out") { model.signOut(appState, serverID: serverID) }
                            .buttonStyle(TagButtonStyle())
                    }
                }
                if let message = model.message {
                    Text(verbatim: message)
                        .safetyNotice(.danger)
                }
                TextField("Client ID (optional)", text: $draft.oauthClientID)
                SecureField("Client Secret (optional)", text: $draft.oauthClientSecret)
                TextField("Callback Port (optional)", text: $draft.oauthCallbackPort)
                LabeledContent("Redirect URI") {
                    Text(verbatim: callbackAddress)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Sign-In")
        } footer: {
            if !hasStaticAuthorization {
                Text("Leave Client ID empty and Parley registers itself with the provider, if the provider allows it. If you register an app by hand, use the redirect URI above, and set a port if the provider needs an exact one. Tokens stay in your login Keychain (not synced). Signing in again clears Always Allow for this server.")
                    .font(.caption)
                    .foregroundStyle(Hideout.inkSoft)
            }
        }
        .task(id: serverID) { await model.load(appState, serverID: serverID) }
        .onDisappear { model.cancel() }
        .sheet(item: Binding(get: { model.review }, set: { if $0 == nil { model.answer(.cancel) } })) { review in
            MCPSignInReviewSheet(review: review) { model.answer($0) }
                .hideoutSheet()
        }
    }

    private var attentionText: String? {
        switch needsAttention {
        case .none: return nil
        case .signIn: return "Sign in required."
        case .moreAccess: return "This server asked for more permission. Sign in again to grant it."
        case .notSaved: return "A renewed sign-in could not be saved to the Keychain. It lasts until Parley quits."
        }
    }
}

/// Everything here came from a server. Hosts are escaped and shown whole, so a long or lookalike name
/// cannot pass for another. No server-chosen name is shown.
struct MCPSignInReviewSheet: View {
    let review: MCPOAuthReview
    let answer: (MCPOAuthAnswer) -> Void

    @ViewState private var picked: String?

    private func host(_ issuer: String) -> String {
        ToolDisplay.address(MCPSignInInfo.authority(ofURL: issuer))
    }

    private var selected: String? { picked ?? review.hosts.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                DecisionHeading(title: Text(verbatim: title))
                content
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noticeCard(fill: Hideout.attentionWash, edge: Hideout.attention)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { answer(.cancel) }
                    .buttonStyle(TagButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { answer(.proceed(host: review.kind == .provider ? selected : nil)) }
                    .buttonStyle(TagButtonStyle(kind: .primary))
                    .disabled(review.kind == .provider && selected == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        switch review.kind {
        case .metadataHost: return "Contact another host?"
        case .provider: return "Sign in to \(ToolDisplay.address(review.server))"
        case .moreHosts: return "Contact more hosts?"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch review.kind {
        case .metadataHost:
            Text("\(ToolDisplay.address(review.server)) keeps its sign-in information on another host. Parley has not contacted it yet.")
            hostList(review.hosts.map(ToolDisplay.address))
            Text("It receives a request from this Mac for that information, and nothing else.")
                .foregroundStyle(Hideout.inkSoft)
        case .moreHosts:
            Text("The provider also uses these hosts. Parley has not contacted them yet.")
            hostList(review.hosts.map(ToolDisplay.address))
            Text("Depending on the host, it receives this server's address, Parley's name and a local address, the sign-in code, or renewal tokens later on.")
                .foregroundStyle(Hideout.inkSoft)
        case .provider:
            providerContent
        }
    }

    @ViewBuilder
    private var providerContent: some View {
        if review.hosts.count > 1 {
            Text("This server offers several sign-in providers. Parley contacts only the one you pick.")
            Picker("Provider", selection: Binding(get: { selected ?? "" }, set: { picked = $0 })) {
                // In full: two providers can share a host and differ by path.
                ForEach(review.hosts, id: \.self) { issuer in
                    Text(verbatim: ToolDisplay.address(issuer)).tag(issuer)
                }
            }
            .labelsHidden()
        } else {
            Text("Parley will contact this sign-in provider, then open it in your browser:")
            hostList(review.hosts.map(host))
        }
        if review.providerDiffers, let selected {
            Text("\(ToolDisplay.address(review.server)) will hold a token issued by \(host(selected)), with the permissions below. That token may also work outside this server.")
                .safetyNotice(.caution)
        }
        if !review.scopes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions requested:")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(review.scopes, id: \.self) { scope in
                        Text(verbatim: ToolDisplay.line(scope) + (review.newScopes.contains(scope) ? " (new)" : ""))
                            .font(.callout.monospaced())
                            .fontDesign(.monospaced)
                            .foregroundStyle(Hideout.boardInk)
                            .textSelection(.enabled)
                    }
                }
                .modifier(BoardPanel())
            }
        }
        Text("The provider receives this server's address, including its path. That address is part of the sign-in page's address, so it stays in your browser history, which may sync.")
            .foregroundStyle(Hideout.inkSoft)
        Text("If Parley has to register, the provider also receives the name Parley and a local address, and keeps a record. If it offers long-lived access, Parley asks for it, and renews the sign-in only when you use this server.")
            .foregroundStyle(Hideout.inkSoft)
    }

    private func hostList(_ hosts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(hosts, id: \.self) { name in
                Text(verbatim: name)
                    .font(.callout.monospaced())
                    .fontDesign(.monospaced)
                    .foregroundStyle(Hideout.boardInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(BoardPanel())
    }
}

/// Addresses and permissions on the chalkboard, the same as a tool's arguments.
private struct BoardPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Hideout.board, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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


/// The title of something that needs a decision: plain and strong, never lettered.
private struct DecisionHeading: View {
    let title: Text

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Hideout.paper)
                .frame(width: 26, height: 26)
                .background(Hideout.attention, in: Circle())
                .accessibilityHidden(true)
            title
                .font(Hideout.title(16))
                .foregroundStyle(Hideout.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
