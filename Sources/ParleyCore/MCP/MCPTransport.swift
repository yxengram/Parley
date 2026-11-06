import Foundation

/// One connection to one server. Handlers are set before `start`. Every `send` ends when its Task
/// is cancelled, so a timeout or Stop never waits for a server; what the server is told about it
/// is MCPClient's business.
protocol MCPTransport: AnyObject, Sendable {
    var isHTTP: Bool { get }
    func start() async throws
    /// One request; returns its response. Inbound messages not tied to it go to `onInbound`.
    func send(_ message: MCPOutbound) async throws -> MCPResponse
    func notify(_ message: MCPOutbound) async throws
    func respond(to id: JSONValue, result: JSONValue?, error: MCPRPCError?, headers: [String: String]) async throws
    /// Forget a server-side session, before a new initialize. Nothing on stdio.
    func resetSession()
    func close(grace: TimeInterval) async
    var onInbound: (@Sendable (MCPInbound) -> Void)? { get set }
    /// The connection ended without `close`. Not called on HTTP, which has no connection to lose.
    var onClosed: (@Sendable (Error?) -> Void)? { get set }
}
