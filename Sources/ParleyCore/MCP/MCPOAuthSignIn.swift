import Foundation

/// What the sheet asks. Every value here came from a server: it is shown through
/// `ToolDisplay.address` and `ToolDisplay.line`, in full, and nothing server-named is shown as a name.
public struct MCPOAuthReview: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// The server's sign-in information is on another host.
        case metadataHost
        /// The main one: the provider or providers, and the scopes.
        case provider
        /// The provider's settings name further hosts.
        case moreHosts
    }

    public let id = UUID()
    public var kind: Kind
    /// The MCP server's host.
    public var server: String
    /// `metadataHost`, `moreHosts`: the new hosts. `provider`: the issuers, as URLs.
    public var hosts: [String]
    public var scopes: [String]
    /// Scopes this server was not granted before.
    public var newScopes: [String]
    /// The provider is not the MCP server: the server will hold a token that may work beyond it.
    public var providerDiffers: Bool

    public static func == (a: Self, b: Self) -> Bool {
        (a.kind, a.server, a.hosts, a.scopes, a.newScopes, a.providerDiffers) == (b.kind, b.server, b.hosts, b.scopes, b.newScopes, b.providerDiffers)
    }

    public init(kind: Kind, server: String, hosts: [String], scopes: [String] = [], newScopes: [String] = [], providerDiffers: Bool = false) {
        self.kind = kind
        self.server = server
        self.hosts = hosts
        self.scopes = scopes
        self.newScopes = newScopes
        self.providerDiffers = providerDiffers
    }
}

public enum MCPOAuthAnswer: Sendable, Equatable {
    /// `host` is the issuer picked, for `.provider`.
    case proceed(host: String?)
    case cancel
}

public typealias MCPOAuthApprove = @Sendable (MCPOAuthReview) async -> MCPOAuthAnswer
/// Opens the system browser. A test passes something that plays the browser.
public typealias MCPOAuthOpen = @Sendable (URL) async -> Bool
/// Runs just before a new token becomes usable. Parley cannot tell which account was chosen in the
/// browser, so what was approved under the last sign-in has to be gone by then.
public typealias MCPOAuthWillSignIn = @Sendable () async -> Void

/// One press of Sign In: the only place Parley goes looking for anything. See "MCP sign-in" in DESIGN.md.
/// Nothing beyond the MCP server is contacted until the sheet has named the host and been answered.
struct MCPOAuthSignIn: Sendable {
    /// How long the browser may take.
    static let browserTimeout: TimeInterval = 300

    let serverID: UUID
    let server: URL
    let secrets: MCPServerSecrets
    let broker: MCPOAuthBroker
    let store: MCPOAuthStore
    let approve: MCPOAuthApprove
    let open: MCPOAuthOpen
    let willSignIn: MCPOAuthWillSignIn
    /// One tokenless request to the server, for its challenge.
    let probe: @Sendable () async throws -> MCPOAuthChallenge?
    var http = MCPOAuthHTTP()
    var now: @Sendable () -> Date = { Date() }

    struct ResourceMetadata {
        var resource: String
        var issuers: [String]
        var scopes: [String]
    }

    struct ServerMetadata {
        var issuer: String
        var authorization: URL
        var token: URL
        var registration: URL?
        var respondsWithIssuer: Bool
        var scopes: [String]
        var authMethods: [String]
        var acceptsURLClientIDs: Bool
    }

    func run() async throws {
        guard !secrets.usesStaticAuthorization else { throw MCPOAuthFailure.staticAuthorization }
        guard server.user == nil, server.password == nil else { throw MCPOAuthFailure.urlHasCredentials }
        guard MCPOAuthPolicy.serverMaySignIn(server), let serverHost = server.host else { throw MCPOAuthFailure.insecureServer }
        let floor = await MCPOAuthHTTP.floor(forServer: serverHost)
        let serverName = MCPOAuthPolicy.authority(server) ?? serverHost

        let start = await broker.beginSignIn(serverURL: server)
        var challenge = start.challenge
        if challenge == nil { challenge = try await probe() }
        let metadata = try await resourceMetadata(challenge: challenge, serverName: serverName, floor: floor)

        let previous = start.previous.flatMap { metadata.issuers.contains($0.issuer) ? $0.scopes : nil } ?? []
        let scopes = MCPOAuthScopes.requested(challenge: MCPOAuthScopes.split(challenge?.scope), supported: metadata.scopes, previous: previous)
        let otherHost = metadata.issuers.contains { URL(string: $0).flatMap(MCPOAuthPolicy.authority) != serverName }
        let review = MCPOAuthReview(kind: .provider, server: serverName, hosts: metadata.issuers, scopes: scopes,
                                    newScopes: previous.isEmpty ? [] : scopes.filter { !previous.contains($0) }, providerDiffers: otherHost)
        guard case .proceed(let picked) = try await ask(review) else { throw MCPOAuthFailure.cancelled }
        let issuer = picked ?? metadata.issuers[0]
        guard metadata.issuers.contains(issuer), let issuerURL = URL(string: issuer) else { throw MCPOAuthFailure.cancelled }

        let provider = try await serverMetadata(issuer: issuer, url: issuerURL, floor: floor)
        var more = [provider.authorization, provider.token]
        if useRegistration(provider), let registration = provider.registration { more.append(registration) }
        let hosts = Self.unique(more.compactMap(MCPOAuthPolicy.authority)).filter {
            $0 != serverName && $0 != MCPOAuthPolicy.authority(issuerURL)
        }
        if !hosts.isEmpty {
            let further = MCPOAuthReview(kind: .moreHosts, server: serverName, hosts: hosts)
            guard case .proceed = try await ask(further) else { throw MCPOAuthFailure.cancelled }
        }

        let (client, listener) = try await client(for: provider, floor: floor)
        defer { listener.close() }
        do {
            try await broker.remember(client, issuer: issuer, epoch: start.epoch)
        } catch let failure as MCPOAuthFailure {
            throw failure
        } catch {
            throw MCPError.secrets("This server's sign-in could not be saved to the Keychain.")
        }
        let redirectURI = listener.redirectURI

        var requested = previous.isEmpty || start.previous?.issuer == issuer ? scopes
            : MCPOAuthScopes.requested(challenge: MCPOAuthScopes.split(challenge?.scope), supported: metadata.scopes, previous: [])
        // Alone it would replace the provider's default scopes with none, so only beside others.
        if !requested.isEmpty, provider.scopes.contains("offline_access"), !requested.contains("offline_access") { requested.append("offline_access") }

        let verifier = MCPOAuthPKCE.randomValue()
        let state = MCPOAuthPKCE.randomValue()
        var fields = ["response_type": "code", "client_id": client.clientID, "redirect_uri": redirectURI,
                      "code_challenge": MCPOAuthPKCE.challenge(for: verifier), "code_challenge_method": "S256",
                      "state": state, "resource": metadata.resource]
        if !requested.isEmpty { fields["scope"] = requested.joined(separator: " ") }
        guard var address = URLComponents(url: provider.authorization, resolvingAgainstBaseURL: false) else { throw MCPOAuthFailure.badResourceMetadata }
        address.percentEncodedQuery = [address.percentEncodedQuery, MCPOAuthForm.encode(fields)].compactMap { $0 }.joined(separator: "&")
        guard let page = address.url, MCPOAuthPolicy.allows(endpoint: page, server: server, floor: floor) else {
            throw MCPOAuthFailure.hostRefused(provider.authorization.host ?? "")
        }
        if let host = page.host { try await MCPOAuthHTTP.check(host: host, floor: floor) }
        listener.expect(state: state)
        guard await open(page) else { throw MCPOAuthFailure.browserFailed }

        let response = try await listener.callback(timeout: Self.browserTimeout)
        listener.close()
        guard MCPOAuthIssuerCheck.accepts(iss: response["iss"], recorded: provider.issuer, supported: provider.respondsWithIssuer) else {
            throw MCPOAuthFailure.responseMismatch
        }
        if let error = response["error"] { throw MCPOAuthFailure.denied(MCPOAuthFailure.code(error)) }
        guard let code = response["code"], !code.isEmpty else { throw MCPOAuthFailure.invalidTokenResponse }

        let answer: MCPOAuthTokenRequest.Answer
        do {
            answer = try await MCPOAuthTokenRequest.send(
                ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI, "code_verifier": verifier,
                 "resource": metadata.resource],
                to: provider.token, clientID: client.clientID, secret: client.clientSecret, method: client.authMethod, http: http, floor: floor)
        } catch let refusal as MCPOAuthTokenRequest.Refusal {
            switch refusal {
            case .invalidClient:
                if !client.isUserEntered { await broker.forgetClient(issuer: issuer) }
                throw MCPOAuthFailure.tokenRefused("invalid_client")
            case .invalidGrant: throw MCPOAuthFailure.tokenRefused("invalid_grant")
            case .other(let code): throw MCPOAuthFailure.tokenRefused(code)
            case .transient: throw MCPOAuthFailure.unreachable
            }
        }

        let tokens = MCPOAuthTokens(
            accessToken: answer.accessToken, refreshToken: answer.refreshToken,
            expiresAt: answer.expiresIn.map { now().addingTimeInterval($0) }, issuer: issuer, resource: metadata.resource,
            tokenEndpoint: provider.token.absoluteString, scopes: requested, clientID: client.clientID,
            clientSecret: client.clientSecret, authMethod: client.authMethod)
        await willSignIn()
        do {
            guard try await broker.accept(tokens, epoch: start.epoch) else { throw MCPOAuthFailure.cancelled }
        } catch let failure as MCPOAuthFailure {
            throw failure
        } catch {
            throw MCPError.secrets("Sign-in finished, but the token could not be saved to the Keychain. Press Sign In to try again.")
        }
    }

    /// A review on a cancelled flow is never shown, and one answered after cancelling does not count.
    private func ask(_ review: MCPOAuthReview) async throws -> MCPOAuthAnswer {
        try Task.checkCancellation()
        let answer = await approve(review)
        try Task.checkCancellation()
        return answer
    }

    private static func unique(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0.lowercased()).inserted }
    }

    private var userClientID: String? {
        let id = secrets.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private func useRegistration(_ provider: ServerMetadata) -> Bool {
        userClientID == nil && provider.registration != nil
    }

    // MARK: Discovery

    private func resourceMetadata(challenge: MCPOAuthChallenge?, serverName: String, floor: MCPOAuthLocality) async throws -> ResourceMetadata {
        var candidates = MCPOAuthDiscovery.resourceMetadataURLs(server: server)
        if let text = challenge?.resourceMetadata, let named = URL(string: text) {
            if MCPOAuthPolicy.sameOrigin(named, server) {
                candidates.insert(named, at: 0)
            } else if MCPOAuthPolicy.allows(endpoint: named, server: server, floor: floor), let host = MCPOAuthPolicy.authority(named) {
                let review = MCPOAuthReview(kind: .metadataHost, server: serverName, hosts: [host])
                guard case .proceed = try await ask(review) else { throw MCPOAuthFailure.cancelled }
                candidates.insert(named, at: 0)
            } else {
                throw MCPOAuthFailure.hostRefused(named.host ?? "")
            }
        }
        for url in candidates {
            try Task.checkCancellation()
            let reply: MCPOAuthHTTP.Reply
            do {
                reply = try await http.get(url, floor: floor)
            } catch let failure as MCPOAuthFailure {
                if case .hostRefused = failure { throw failure }
                continue
            }
            guard reply.status == 200 else { continue }
            guard let body = JSONValue(jsonData: reply.data), let resource = body["resource"]?.stringValue,
                  let issuers = body["authorization_servers"]?.arrayValue?.compactMap(\.stringValue), !issuers.isEmpty else {
                throw MCPOAuthFailure.badResourceMetadata
            }
            guard MCPOAuthResource.matches(resource, server: server) else { throw MCPOAuthFailure.resourceMismatch }
            let scopes = MCPOAuthScopes.unique(body["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var usable: [String] = []
            for issuer in Self.unique(issuers) {
                guard let url = URL(string: issuer), url.query == nil else { continue }
                if MCPOAuthPolicy.allows(endpoint: url, server: server, floor: floor) { usable.append(issuer) }
            }
            guard !usable.isEmpty else {
                throw MCPOAuthFailure.hostRefused(URL(string: issuers[0])?.host ?? "")
            }
            return ResourceMetadata(resource: resource, issuers: usable, scopes: scopes)
        }
        throw MCPOAuthFailure.notProtected
    }

    private func serverMetadata(issuer: String, url: URL, floor: MCPOAuthLocality) async throws -> ServerMetadata {
        for candidate in MCPOAuthDiscovery.authorizationServerURLs(issuer: url) {
            try Task.checkCancellation()
            let reply: MCPOAuthHTTP.Reply
            do {
                reply = try await http.get(candidate, floor: floor)
            } catch let failure as MCPOAuthFailure {
                if case .hostRefused = failure { throw failure }
                continue
            }
            guard reply.status == 200, let body = JSONValue(jsonData: reply.data) else { continue }
            // Identical, as a string: anything else is another provider's document.
            guard body["issuer"]?.stringValue == issuer else { throw MCPOAuthFailure.issuerMismatch }
            guard body["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue).contains("S256") == true else {
                throw MCPOAuthFailure.noPKCE
            }
            func endpoint(_ name: String) throws -> URL? {
                guard let text = body[name]?.stringValue else { return nil }
                guard let url = URL(string: text), MCPOAuthPolicy.allows(endpoint: url, server: server, floor: floor) else {
                    throw MCPOAuthFailure.hostRefused(URL(string: text)?.host ?? "")
                }
                return url
            }
            guard let authorization = try endpoint("authorization_endpoint"), let token = try endpoint("token_endpoint") else {
                throw MCPOAuthFailure.metadataNotFound
            }
            if let types = body["response_types_supported"]?.arrayValue?.compactMap(\.stringValue), !types.contains("code") {
                throw MCPOAuthFailure.metadataNotFound
            }
            return ServerMetadata(
                issuer: issuer, authorization: authorization, token: token, registration: try endpoint("registration_endpoint"),
                respondsWithIssuer: body["authorization_response_iss_parameter_supported"]?.boolValue == true,
                scopes: body["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                authMethods: body["token_endpoint_auth_methods_supported"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                acceptsURLClientIDs: body["client_id_metadata_document_supported"]?.boolValue == true)
        }
        throw MCPOAuthFailure.metadataNotFound
    }

    // MARK: Client

    /// The listener is bound first: registration needs the real redirect URI, and a provider that
    /// compares exactly refuses a client whose port has changed.
    private func client(for provider: ServerMetadata, floor: MCPOAuthLocality) async throws -> (MCPOAuthClient, MCPOAuthLoopback) {
        let fixedPort = secrets.oauthCallbackPort ?? 0
        // An unreadable item is not an empty one: the check below depends on it.
        let known: [String: MCPOAuthClient]
        do {
            known = try store.clients(for: serverID)
        } catch {
            throw MCPError.secrets("This server's sign-in could not be read from the Keychain.")
        }
        if let id = userClientID {
            // A new Client ID beside an old secret is the same mistake: the secret is what must not move.
            let secretToSend = secrets.oauthClientSecret
            let elsewhere = known.filter { $0.key != provider.issuer && $0.value.isUserEntered }
            if elsewhere.values.contains(where: { $0.clientID == id || (!secretToSend.isEmpty && $0.clientSecret == secretToSend) }) {
                throw MCPOAuthFailure.clientIssuerChanged
            }
            if let url = URL(string: id), url.scheme?.lowercased() == "https",
               !provider.acceptsURLClientIDs || url.path.isEmpty || url.path == "/" {
                throw MCPOAuthFailure.clientMetadataUnsupported
            }
            let secret = secrets.oauthClientSecret.isEmpty ? nil : secrets.oauthClientSecret
            let method = secret == nil ? "none" : provider.authMethods.contains("client_secret_post") ? "client_secret_post" : "client_secret_basic"
            let listener = try MCPOAuthLoopback(port: fixedPort)
            return (MCPOAuthClient(clientID: id, clientSecret: secret, authMethod: method, redirectURI: listener.redirectURI, isUserEntered: true), listener)
        }
        if let stored = known[provider.issuer], !stored.isUserEntered, let redirect = stored.redirectURI,
           let port = URL(string: redirect)?.port, fixedPort == 0 || fixedPort == port {
            do {
                return (stored, try MCPOAuthLoopback(port: port))
            } catch MCPOAuthFailure.portBusy {
                // Registered for a port that is taken now: a new registration, not a mismatched URI.
            }
        }
        guard let registration = provider.registration else { throw MCPOAuthFailure.clientIDRequired }
        let listener = try MCPOAuthLoopback(port: fixedPort)
        let body: JSONValue = .object([
            "client_name": .string("Parley"),
            "application_type": .string("native"),
            "redirect_uris": .array([.string(listener.redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ])
        do {
            let reply = try await http.post(registration, json: body, floor: floor)
            guard (200..<300).contains(reply.status), let answer = JSONValue(jsonData: reply.data),
                  let id = answer["client_id"]?.stringValue, !id.isEmpty else { throw MCPOAuthFailure.registrationRefused }
            let secret = answer["client_secret"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let method = answer["token_endpoint_auth_method"]?.stringValue ?? (secret == nil ? "none" : "client_secret_basic")
            return (MCPOAuthClient(clientID: id, clientSecret: secret, authMethod: method, redirectURI: listener.redirectURI, isUserEntered: false), listener)
        } catch {
            listener.close()
            throw error
        }
    }
}
