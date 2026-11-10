import Darwin
import Foundation
import Network

/// The gate every request of a `browse_url` page passes: an HTTP CONNECT proxy on loopback, one per
/// call, that the page's private data store is pointed at. WebKit tunnels http and https through it
/// alike, so it sees the host and port of every connection the page opens (scripts, XHR, fetch,
/// WebSockets, frames, redirects), where a navigation delegate sees only frames.
///
/// For each CONNECT the host's own name must be at or above the floor, it is looked up once, every
/// address it has must be at or above the floor too, and the tunnel goes to one of those checked
/// addresses, never to the name. So there is no second lookup for a rebinding name to change, which
/// `fetch_url` has. The connected address is checked once more before the tunnel opens.
///
/// WebKit connects to 127.0.0.0/8, `::1` and `localhost` without asking any proxy; `BuiltInBrowsePolicy`
/// blocks those in the page with content rules. Everything else on the LAN comes through here.
///
/// Only what the proxy needs is kept: hosts it refused or could not reach, for the note to the model.
final class BuiltInBrowseProxy: @unchecked Sendable {
    /// Per page, both ways together. A page that streams video or loops downloads stops here.
    static let maxBytes = 64 * 1024 * 1024
    static let maxTunnels = 48
    private static let maxHeaderBytes = 8 * 1024
    private static let connectTimeout: TimeInterval = 20
    private static let maxRecordedHosts = 20

    enum HostOutcome: Equatable, Sendable {
        case refused
        /// Not the approved site, while only that site is allowed. Never looked up.
        case otherSite
        case notFound
        case unreachable
    }

    private let floor: MCPOAuthLocality
    private let byteLimit: Int
    private let queue = DispatchQueue(label: "parley.browse.proxy")
    private let listener: NWListener
    // Below: only on `queue`.
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]
    private var bytes = 0
    private var stopped = false
    private var outcomes: [String: HostOutcome] = [:]
    private var outcomeOrder: [String] = []
    private var refusedCount = 0
    private var otherSiteHostCount = 0
    /// Every other site (host and port) refused, for the count. Bounded, so a page that names
    /// endless hosts cannot grow it without limit.
    private var otherSites: Set<String> = []
    private static let maxCountedSites = 10_000
    /// With a value, only this host and port may be reached: the approved site.
    private let onlySite: (host: String, port: UInt16)?
    private var overBudget = false
    private var allowedHosts: [String] = []

    /// The app's floor is `.remote`. Tests on loopback lower it, and lower the byte limit.
    /// `onlySite` is the approved site's host and port when other sites are not allowed. That is
    /// the one place the choice is enforced: WebKit opens every connection off this Mac through here.
    init(floor: MCPOAuthLocality, byteLimit: Int = BuiltInBrowseProxy.maxBytes, onlySite: (host: String, port: UInt16)? = nil) throws {
        self.floor = floor
        self.byteLimit = byteLimit
        self.onlySite = onlySite.map { (Self.normalized($0.host), $0.port) }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// The port to give WebKit, once the listener is up.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let port = self?.listener.port?.rawValue, port != 0 {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: CancellationError())
                    }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Closes the listener and every tunnel. Safe to call more than once, from any thread.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            listener.cancel()
            for tunnel in tunnels.values { tunnel.close() }
            tunnels.removeAll()
        }
    }

    /// Hosts the page asked for and did not get, in the order they first came up.
    var hostOutcomes: [(host: String, outcome: HostOutcome)] {
        queue.sync { outcomeOrder.map { ($0, outcomes[$0]!) } }
    }

    func outcome(for host: String) -> HostOutcome? {
        queue.sync { outcomes[Self.normalized(host)] }
    }

    var hitByteLimit: Bool { queue.sync { overBudget } }

    /// How many other sites (host and port) the page tried and was refused. Sites, not requests:
    /// WebKit tries a refused CONNECT several times, and one connection can carry many requests,
    /// so a count of either would be wrong.
    var otherSitesBlocked: Int { queue.sync { otherSites.count } }

    // MARK: Connections

    private func accept(_ client: NWConnection) {
        // Past the byte limit the page gets nothing more: no lookup, no connection.
        guard !stopped, !overBudget, tunnels.count < Self.maxTunnels else {
            client.cancel()
            return
        }
        let tunnel = Tunnel(client: client)
        let id = ObjectIdentifier(tunnel)
        tunnels[id] = tunnel
        tunnel.onClose = { [weak self] in self?.tunnels[id] = nil }
        client.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: tunnel.close()
            default: break
            }
        }
        client.start(queue: queue)
        readHeader(tunnel, buffered: Data())
    }

    private func readHeader(_ tunnel: Tunnel, buffered: Data) {
        tunnel.client.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { tunnel.close(); return }
            var header = buffered
            if let data { header.append(data) }
            if let end = header.range(of: Data("\r\n\r\n".utf8)) {
                let rest = header[end.upperBound...]
                self.handle(BuiltInBrowsePolicy.parseConnect(header[..<end.lowerBound]), tunnel: tunnel, early: Data(rest))
            } else if header.count >= Self.maxHeaderBytes || isComplete || error != nil {
                self.answer(tunnel, "400 Bad Request")
            } else {
                self.readHeader(tunnel, buffered: header)
            }
        }
    }

    private func handle(_ request: BuiltInBrowsePolicy.ConnectRequest?, tunnel: Tunnel, early: Data) {
        guard let request else {
            answer(tunnel, "405 Method Not Allowed")
            return
        }
        let host = Self.normalized(request.host)
        // The site first: another one is not looked up at all.
        if let onlySite, !BuiltInBrowsePolicy.isSameSite(host: host, port: request.port, as: onlySite) {
            if otherSites.count < Self.maxCountedSites { otherSites.insert("\(host):\(request.port)") }
            record(host, .otherSite)
            answer(tunnel, "403 Forbidden")
            return
        }
        guard let named = MCPOAuthPolicy.locality(ofHost: host), named >= floor else {
            record(host, .refused)
            answer(tunnel, "403 Forbidden")
            return
        }
        let floor = self.floor
        // A lookup blocks and cannot be interrupted, so it runs off this queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let addresses = BuiltInBrowseProxy.lookUp(host)
            guard let self else { return }
            self.queue.async {
                // WebKit may have given up on this request during the lookup.
                guard !self.stopped, !self.overBudget, !tunnel.isClosed else { tunnel.close(); return }
                if addresses.isEmpty {
                    self.record(host, .notFound)
                    self.answer(tunnel, "502 Bad Gateway")
                    return
                }
                // Every address, as `fetch_url` judges a name by its closest one.
                guard addresses.allSatisfy({ MCPOAuthHTTP.addressIsAllowed($0, floor: floor) }) else {
                    self.record(host, .refused)
                    self.answer(tunnel, "403 Forbidden")
                    return
                }
                self.connect(tunnel, host: host, addresses: addresses, port: request.port, early: early)
            }
        }
    }

    private func connect(_ tunnel: Tunnel, host: String, addresses: [String], port: UInt16, early: Data) {
        guard !stopped, !overBudget, !tunnel.isClosed else { tunnel.close(); return }
        guard let address = addresses.first, let nwPort = NWEndpoint.Port(rawValue: port) else {
            record(host, .unreachable)
            answer(tunnel, "502 Bad Gateway")
            return
        }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Int(Self.connectTimeout)
        }
        let upstream = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: parameters)
        tunnel.upstream = upstream
        let floor = self.floor
        var established = false
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped, !tunnel.isClosed else { upstream.cancel(); tunnel.close(); return }
            // Once the tunnel is open, a failure is the end of it: no retry, no answer in the middle
            // of the page's bytes, and nothing to record.
            if established {
                if case .failed = state { tunnel.close() }
                return
            }
            switch state {
            case .ready:
                established = true
                // Where it really went, in case anything between here and the socket chose otherwise.
                if case .hostPort(let connected, _)? = upstream.currentPath?.remoteEndpoint,
                   !MCPOAuthHTTP.addressIsAllowed(Self.text(of: connected), floor: floor) {
                    self.record(host, .refused)
                    self.answer(tunnel, "403 Forbidden")
                    return
                }
                tunnel.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                if !early.isEmpty { self.forward(early, to: upstream, tunnel: tunnel) }
                self.pipe(from: tunnel.client, to: upstream, tunnel: tunnel)
                self.pipe(from: upstream, to: tunnel.client, tunnel: tunnel)
            case .waiting, .failed:
                // The next address, as a browser tries each one.
                let rest = Array(addresses.dropFirst())
                upstream.stateUpdateHandler = nil
                upstream.cancel()
                if rest.isEmpty {
                    self.record(host, .unreachable)
                    self.answer(tunnel, "502 Bad Gateway")
                } else {
                    self.connect(tunnel, host: host, addresses: rest, port: port, early: early)
                }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pipe(from source: NWConnection, to target: NWConnection, tunnel: Tunnel) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped, !tunnel.isClosed else { tunnel.close(); return }
            let done = isComplete || error != nil
            if let data, !data.isEmpty {
                // When one side is done, what it sent last still reaches the other before both close:
                // a cancel drops sends that are still queued.
                self.forward(data, to: target, tunnel: tunnel, then: done ? { tunnel.close() } : nil)
            } else if done {
                target.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in tunnel.close() })
            }
            if !done { self.pipe(from: source, to: target, tunnel: tunnel) }
        }
    }

    private func forward(_ data: Data, to target: NWConnection, tunnel: Tunnel, then: (() -> Void)? = nil) {
        bytes += data.count
        if bytes > byteLimit {
            overBudget = true
            for open in tunnels.values { open.close() }
            tunnels.removeAll()
            return
        }
        target.send(content: data, completion: .contentProcessed { _ in then?() })
    }

    private func answer(_ tunnel: Tunnel, _ status: String) {
        let text = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        tunnel.client.send(content: Data(text.utf8), completion: .contentProcessed { _ in tunnel.close() })
    }

    /// Refused hosts and the rest are capped apart, so dead tracker names cannot crowd out a LAN
    /// address the page tried.
    private func record(_ host: String, _ outcome: HostOutcome) {
        guard outcomes[host] == nil else { return }
        switch outcome {
        case .refused:
            guard refusedCount < Self.maxRecordedHosts else { return }
            refusedCount += 1
        case .otherSite:
            guard otherSiteHostCount < Self.maxRecordedHosts else { return }
            otherSiteHostCount += 1
        case .notFound, .unreachable:
            guard outcomeOrder.count - refusedCount - otherSiteHostCount < Self.maxRecordedHosts else { return }
        }
        outcomes[host] = outcome
        outcomeOrder.append(host)
    }

    // MARK: Addresses

    static func normalized(_ host: String) -> String {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private static func text(of host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%")[0]
        case .ipv6(let address): return "\(address)".components(separatedBy: "%")[0]
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }

    /// Numeric addresses, in the resolver's order. Empty when the name does not resolve.
    static func lookUp(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var found: [String] = []
        var entry = list
        while let current = entry {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = current.pointee.ai_addr,
               getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer).components(separatedBy: "%")[0]
                if !found.contains(text) { found.append(text) }
            }
            entry = current.pointee.ai_next
        }
        return found
    }
}

/// One CONNECT: the page's side and, once checked, the site's.
private final class Tunnel {
    let client: NWConnection
    /// Set after `close` (a lookup or a connect that was under way) is cancelled at once, so no
    /// connection outlives its tunnel.
    var upstream: NWConnection? {
        didSet {
            if isClosed, let upstream { upstream.stateUpdateHandler = nil; upstream.cancel() }
        }
    }
    var onClose: (() -> Void)?
    private(set) var isClosed = false

    init(client: NWConnection) { self.client = client }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        let done = onClose
        onClose = nil
        done?()
    }
}

/// True once, for a continuation that more than one callback may want to resume.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}
