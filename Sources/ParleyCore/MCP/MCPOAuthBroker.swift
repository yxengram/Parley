import Foundation

/// What the HTTP transport needs from sign-in. Nil on a server with a static Authorization header.
protocol MCPHTTPAuthorizer: AnyObject, Sendable {
    /// The token for the next request, or nil without a sign-in. Only a request from a send or Connect
    /// may set `mayRefresh`.
    func token(mayRefresh: Bool) async throws -> String?
    /// The server answered 401 to `token`. A new token to retry with, or nil when only a new sign-in
    /// can help. Throws when the provider could not be reached: the sign-in may still be good.
    func replacement(forRejected token: String) async throws -> String?
    /// Kept for the next Sign In: it contacts nobody now, and the challenge names what is needed.
    func received(_ challenge: MCPOAuthChallenge, status: Int) async
}

/// A value several callers wait for, where one caller giving up leaves the work running.
final class MCPOAuthShared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiting: [UUID: CheckedContinuation<Value, Error>] = [:]

    /// Ends with the value, or with CancellationError when the calling Task is cancelled.
    func wait() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if let value {
                    continuation.resume(returning: value)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[id] = continuation
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    func finish(_ result: Value) {
        lock.lock()
        value = result
        let all = waiting
        waiting = [:]
        lock.unlock()
        for continuation in all.values { continuation.resume(returning: result) }
    }
}

/// Set once, at quit, from a synchronous path.
final class MCPOAuthFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// One server's sign-in, outliving its connections. Being an actor is the rule against races: every
/// write and delete of its Keychain item happens here, ordered, and a result applies only if nothing
/// ended the sign-in it started from. So a late refresh, or a Sign In still open in the browser,
/// cannot bring a token back after Delete, a URL change or Sign Out.
///
/// Public clients get rotating refresh tokens: the provider has already spent the old one when it
/// answers. So a refresh is shared by everyone waiting, runs in its own task and session, and is not
/// cancelled with any of them. A caller's timeout or Stop ends only that caller's wait.
actor MCPOAuthBroker: MCPHTTPAuthorizer {
    enum Refreshed: Sendable {
        case token(String)
        case signInNeeded
        case failed
    }

    private let serverID: UUID
    private let store: MCPOAuthStore
    private let http = MCPOAuthHTTP()
    private let quitting: MCPOAuthFlag
    private let now: @Sendable () -> Date
    private var observer: (@Sendable (MCPSignInNeed?) -> Void)?

    private var current: MCPOAuthTokens?
    private var serverURL: URL?
    /// What a running refresh started from: Sign Out, Delete, a URL change or a finished Sign In move it.
    private var generation = 0
    /// What a Sign In in the browser started from: only Sign Out, Delete and a URL change move it.
    private var signInEpoch = 0
    private var refresh: MCPOAuthShared<Refreshed>?
    private var challenge: MCPOAuthChallenge?
    private var challengeStatus = 0
    /// `current` was renewed and the Keychain refused it, so what the Keychain holds is already spent.
    private var unsaved = false

    init(serverID: UUID, store: MCPOAuthStore, quitting: MCPOAuthFlag, now: @escaping @Sendable () -> Date = { Date() }) {
        self.serverID = serverID
        self.store = store
        self.quitting = quitting
        self.now = now
    }

    func setObserver(_ observer: @escaping @Sendable (MCPSignInNeed?) -> Void) {
        self.observer = observer
    }

    /// A connection to `url` is starting. A stored sign-in for another address stays unused.
    func attach(serverURL url: URL) throws {
        serverURL = url
        if unsaved, let kept = current {
            guard MCPOAuthResource.matches(kept.resource, server: url) else {
                current = nil
                return
            }
            if (try? store.setTokens(kept, for: serverID)) != nil {
                unsaved = false
            } else {
                observer?(.notSaved)
            }
            return
        }
        if let stored = try store.tokens(for: serverID), MCPOAuthResource.matches(stored.resource, server: url),
           MCPOAuthPolicy.serverMaySignIn(url) {
            if refresh == nil { current = stored }
        } else {
            current = nil
        }
    }

    var info: MCPSignInInfo? {
        guard let tokens = current ?? (try? store.tokens(for: serverID)) ?? nil else { return nil }
        return MCPSignInInfo(provider: MCPSignInInfo.authority(ofURL: tokens.issuer), scopes: tokens.scopes)
    }

    // MARK: Tokens

    func token(mayRefresh: Bool) async throws -> String? {
        guard let tokens = current else { return nil }
        guard mayRefresh, let expiresAt = tokens.expiresAt, expiresAt.timeIntervalSince(now()) < 60 else {
            return tokens.accessToken
        }
        let expired = expiresAt <= now()
        guard tokens.refreshToken != nil else {
            if expired { throw MCPError.needsAuthorization(status: 401) }
            return tokens.accessToken
        }
        switch try await sharedRefresh().wait() {
        case .token(let fresh): return fresh
        case .signInNeeded: throw MCPError.needsAuthorization(status: 401)
        case .failed:
            if expired { throw MCPError.oauth(.refreshFailed) }
            return current?.accessToken
        }
    }

    func replacement(forRejected token: String) async throws -> String? {
        guard let tokens = current else { return nil }
        // Someone else's refresh got there first.
        if tokens.accessToken != token { return tokens.accessToken }
        guard tokens.refreshToken != nil else { return nil }
        switch try await sharedRefresh().wait() {
        case .token(let fresh): return fresh
        case .signInNeeded: return nil
        case .failed: throw MCPError.oauth(.refreshFailed)
        }
    }

    func received(_ challenge: MCPOAuthChallenge, status: Int) {
        self.challenge = challenge
        challengeStatus = status
    }

    private func sharedRefresh() -> MCPOAuthShared<Refreshed> {
        if let refresh { return refresh }
        let shared = MCPOAuthShared<Refreshed>()
        refresh = shared
        Task.detached { await self.runRefresh(shared) }
        return shared
    }

    private func runRefresh(_ shared: MCPOAuthShared<Refreshed>) async {
        let outcome = await refreshOutcome()
        refresh = nil
        shared.finish(outcome)
    }

    private func refreshOutcome() async -> Refreshed {
        let started = generation
        guard let sent = current, let refreshToken = sent.refreshToken, !quitting.isSet,
              let endpoint = URL(string: sent.tokenEndpoint), let server = serverURL, let host = server.host else { return .failed }
        let floor = await MCPOAuthHTTP.floor(forServer: host)
        guard MCPOAuthPolicy.allows(endpoint: endpoint, server: server, floor: floor) else { return .failed }
        let answer: MCPOAuthTokenRequest.Answer
        do {
            answer = try await MCPOAuthTokenRequest.send(
                ["grant_type": "refresh_token", "refresh_token": refreshToken, "resource": sent.resource],
                to: endpoint, clientID: sent.clientID, secret: sent.clientSecret, method: sent.authMethod, http: http, floor: floor)
        } catch MCPOAuthTokenRequest.Refusal.invalidGrant {
            discard(sent, started: started)
            return settled(after: sent)
        } catch MCPOAuthTokenRequest.Refusal.invalidClient {
            discard(sent, started: started)
            // A client typed in stays: it is what ties that Client ID to this provider.
            if generation == started, var clients = try? store.clients(for: serverID), clients[sent.issuer]?.isUserEntered != true {
                clients[sent.issuer] = nil
                try? store.setClients(clients, for: serverID)
            }
            return settled(after: sent)
        } catch {
            return .failed
        }
        // The sign-in this refresh belongs to has ended: its result must not bring it back. A newer
        // sign-in may have replaced it, and then that token is the answer.
        guard generation == started, current != nil else { return settled(after: sent) }
        var merged = sent
        merged.accessToken = answer.accessToken
        // Absent means the old one still works, on a provider that does not rotate.
        merged.refreshToken = answer.refreshToken ?? refreshToken
        merged.expiresAt = answer.expiresIn.map { now().addingTimeInterval($0) }
        current = merged
        do {
            try store.setTokens(merged, for: serverID)
            unsaved = false
        } catch {
            // Already spent at the provider: this copy is all there is, for this run.
            unsaved = true
            observer?(.notSaved)
        }
        return .token(merged.accessToken)
    }

    /// What a refresh's waiters get when its own result does not count.
    private func settled(after sent: MCPOAuthTokens) -> Refreshed {
        if let newer = current, newer.accessToken != sent.accessToken { return .token(newer.accessToken) }
        return .signInNeeded
    }

    /// Only if the item still holds what was sent: a newer sign-in must not lose its token.
    private func discard(_ sent: MCPOAuthTokens, started: Int) {
        guard generation == started, current?.refreshToken == sent.refreshToken else { return }
        current = nil
        unsaved = false
        try? store.deleteTokens(for: serverID)
        observer?(.signIn)
    }

    // MARK: Sign In and Sign Out

    /// `previous` comes from the Keychain before anything ran this launch: a step-up must not lose
    /// what was granted earlier.
    func beginSignIn(serverURL url: URL) -> (epoch: Int, previous: MCPOAuthTokens?, challenge: MCPOAuthChallenge?, status: Int) {
        let stored = current ?? (try? store.tokens(for: serverID)) ?? nil
        let previous = stored.flatMap { MCPOAuthResource.matches($0.resource, server: url) ? $0 : nil }
        return (signInEpoch, previous, challenge, challengeStatus)
    }

    /// Kept as soon as it exists, before any step that can be abandoned: a registration so the next
    /// attempt leaves no second record, a typed-in client so its secret stays tied to this provider.
    func remember(_ client: MCPOAuthClient, issuer: String, epoch: Int) throws {
        guard epoch == signInEpoch else { throw MCPOAuthFailure.cancelled }
        var clients = try store.clients(for: serverID)
        clients[issuer] = client
        try store.setClients(clients, for: serverID)
    }

    /// False: Sign Out, Delete or a URL change came first, and the sign-in in the browser is void.
    func accept(_ tokens: MCPOAuthTokens, epoch: Int) throws -> Bool {
        guard epoch == signInEpoch else { return false }
        try store.setTokens(tokens, for: serverID)
        generation += 1
        current = tokens
        unsaved = false
        challenge = nil
        challengeStatus = 0
        return true
    }

    func forgetClient(issuer: String) {
        guard var clients = try? store.clients(for: serverID) else { return }
        clients[issuer] = nil
        try? store.setClients(clients, for: serverID)
    }

    /// Removes the sign-in, and everything running stops counting, in one step. Registered clients
    /// stay unless the server itself is going. A connection being closed still has its token for
    /// the session's DELETE: the transport keeps the last one it used.
    func clear(includingClients: Bool) throws {
        generation += 1
        signInEpoch += 1
        current = nil
        unsaved = false
        challenge = nil
        challengeStatus = 0
        try store.deleteTokens(for: serverID)
        if includingClients { try store.setClients([:], for: serverID) }
    }
}
