import Foundation

// Context-length discovery and (LM Studio only) changing it by reloading the model.
//
// Privacy: every request goes to the configured provider's own scheme, host and port, through
// ChatClient's ephemeral, redirect-refusing session with the same Authorization header. Nothing
// is looked up anywhere else. Probes are read-only GETs with a short timeout; any failure
// (401/403/404, HTML, an LM Studio-style 200 {"error":…}) just means "not known".
//
// Probe order for a model:
//  1. GET {base}/models (the list Parley already fetches): vLLM max_model_len, llama.cpp
//     meta.n_ctx / n_ctx_train, hosted context_length / context_window / max_context_length.
//  2. Native endpoints on {root} = base URL minus a trailing "/v1", only when the host is local
//     (loopback, LAN, Tailscale) or the list above looks like LM Studio or llama.cpp:
//     LM Studio GET /api/v1/models, then GET /api/v0/models (servers before 0.4),
//     Strata GET /health (service "strata"), llama.cpp GET /props, Ollama GET /api/ps.
//     The first that validates wins.
// /slots (llama.cpp, Strata) is never read: it exposes other clients' prompts.
//
// Strata has two HTTP surfaces:
//  - the desktop app's "share on network" port (by default 47832): only GET /v1/models,
//    POST /v1/chat/completions and /v1/messages exist, everything else is a 404. Its list says
//    owned_by "strata"; a loaded native model has no context field there (Strata issue #3931), the
//    runtime mode has meta.context. Nothing else is probed on it.
//  - the engine server itself (serve/server.py, also PolyStrata): its list has no owned_by but
//    status.value and meta.n_ctx per model, and GET /health (no key needed) says service "strata"
//    with max_context, images and loaded.
// Strata fixes the context length when it starts the model; it cannot be changed through the API.

public enum InferenceServerKind: String, Sendable, Hashable {
    case lmStudio, llamaCpp, vLLM, ollama, strata, hosted

    public var displayName: String {
        switch self {
        case .lmStudio: return "LM Studio"
        case .llamaCpp: return "llama.cpp"
        case .vLLM: return "vLLM"
        case .ollama: return "Ollama"
        case .strata: return "Strata"
        case .hosted: return "OpenAI-compatible API"
        }
    }
}

/// What a server says about one model's context window.
public struct ModelContextInfo: Sendable, Equatable {
    public var model: String
    public var serverKind: InferenceServerKind?
    /// The context length the server uses for this model right now: LM Studio's loaded instance,
    /// llama.cpp's per-slot n_ctx, vLLM's max_model_len, Ollama's running context, a hosted
    /// model's context window.
    public var loadedContextLength: Int?
    /// The most the model supports (LM Studio max_context_length, llama.cpp n_ctx_train).
    public var maxContextLength: Int?
    /// LM Studio and Ollama say whether the model is in memory; nil when unknown.
    public var isLoaded: Bool?
    /// True only for LM Studio 0.4+ (REST load/unload with a context_length).
    public var canSetContextLength: Bool
    /// LM Studio model key (the chat id may be an instance id such as "key:2").
    public var modelKey: String?
    /// LM Studio loaded instance ids for this model.
    public var instanceIDs: [String]
    /// Whether the model reads images: false when the server says it cannot (Strata's engine
    /// /health "images", an input_modalities list without "image", or an earlier refusal).
    /// Nil when unknown.
    public var acceptsImages: Bool?
    /// The largest request body the server accepts, when it is known to be small (Strata's
    /// shared port: 12 MiB, 4 MiB in its runtime mode). Images are re-sent with every request.
    public var maxRequestBytes: Int?

    public init(
        model: String,
        serverKind: InferenceServerKind? = nil,
        loadedContextLength: Int? = nil,
        maxContextLength: Int? = nil,
        isLoaded: Bool? = nil,
        canSetContextLength: Bool = false,
        modelKey: String? = nil,
        instanceIDs: [String] = [],
        acceptsImages: Bool? = nil,
        maxRequestBytes: Int? = nil
    ) {
        self.model = model
        self.serverKind = serverKind
        self.loadedContextLength = loadedContextLength
        self.maxContextLength = maxContextLength
        self.isLoaded = isLoaded
        self.canSetContextLength = canSetContextLength
        self.modelKey = modelKey
        self.instanceIDs = instanceIDs
        self.acceptsImages = acceptsImages
        self.maxRequestBytes = maxRequestBytes
    }

    /// Later (more specific) values win; nil never overwrites a value.
    mutating func merge(_ other: ModelContextInfo) {
        serverKind = other.serverKind ?? serverKind
        loadedContextLength = other.loadedContextLength ?? loadedContextLength
        maxContextLength = other.maxContextLength ?? maxContextLength
        isLoaded = other.isLoaded ?? isLoaded
        canSetContextLength = canSetContextLength || other.canSetContextLength
        modelKey = other.modelKey ?? modelKey
        if !other.instanceIDs.isEmpty { instanceIDs = other.instanceIDs }
        acceptsImages = other.acceptsImages ?? acceptsImages
        maxRequestBytes = other.maxRequestBytes ?? maxRequestBytes
    }
}

/// Strata's shared port reads at most this much of a request body (apps/host/server/index.mjs,
/// readBody(req, 12 MiB)); a larger one is answered with a plain-text HTTP 500 "Request failed".
public let strataShareBodyLimit = 12 * 1024 * 1024
/// The same port in its runtime mode (no native model): readBody's default of 4 MiB.
public let strataRuntimeBodyLimit = 4 * 1024 * 1024

extension ChatClient {
    static let probeTimeout: TimeInterval = 5
    /// Loading a large model can take minutes (same budget as a chat request).
    static let loadTimeout: TimeInterval = 600
    static let unloadTimeout: TimeInterval = 120

    /// The server root for native (non-OpenAI) endpoints: the base URL with its trailing "/v1"
    /// removed. Nil unless the path ends exactly in "/v1".
    public var nativeAPIRoot: URL? {
        let path = baseURL.path
        guard path == "/v1" || path.hasSuffix("/v1") else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = String(path.dropLast(3))
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    /// Discovers the model's context length. Never throws and never blocks chatting: anything
    /// that fails or times out is simply unknown.
    public func fetchModelInfo(model: String) async -> ModelContextInfo {
        var info = ModelContextInfo(model: model)
        let list = await probeJSON(modelsURL)
        if let list, let generic = Self.parseModelList(list, model: model) {
            info.merge(generic)
        }
        // vLLM's list is authoritative and it has no other endpoint worth asking. Strata's shared
        // port (owned_by "strata") serves nothing but the models list and the chat endpoints.
        if info.serverKind == .vLLM || info.serverKind == .strata { return info }

        guard let root = nativeAPIRoot, let host = baseURL.host else { return info }
        let looksStrata = list.map(Self.looksLikeStrataEngine) ?? false
        let looksNative = info.serverKind == .lmStudio || info.serverKind == .llamaCpp || looksStrata
        // Hosted APIs (OpenAI, OpenRouter, …) would only answer these with 404s.
        guard Self.isLocalHost(host) || looksNative else { return info }

        typealias Probe = () async -> ModelContextInfo?
        let lmStudioV1: Probe = {
            await self.probeJSON(Self.url(root, "api/v1/models")).flatMap { Self.parseLMStudioV1($0, model: model) }
        }
        let lmStudioV0: Probe = {
            await self.probeJSON(Self.url(root, "api/v0/models")).flatMap { Self.parseLMStudioV0($0, model: model) }
        }
        let llamaProps: Probe = {
            if let props = await self.probeJSON(Self.url(root, "props")), let parsed = Self.parseLlamaCppProps(props) {
                return parsed
            }
            // Router mode needs ?model=<id> (400 "model name is missing" without it).
            var c = URLComponents(url: Self.url(root, "props"), resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "model", value: model)]
            guard let withModel = c?.url else { return nil }
            return await self.probeJSON(withModel).flatMap { Self.parseLlamaCppProps($0) }
        }
        let ollamaPS: Probe = {
            await self.probeJSON(Self.url(root, "api/ps")).flatMap { Self.parseOllamaPS($0, model: model) }
        }
        // Strata's engine also answers /props (llama.cpp's shape), so /health goes first.
        let strataHealth: Probe = {
            await self.probeJSON(Self.url(root, "health")).flatMap { Self.parseStrataHealth($0, model: model) }
        }
        let order: [Probe]
        if info.serverKind == .llamaCpp {
            order = [llamaProps]
        } else if looksStrata {
            order = [strataHealth, llamaProps]
        } else {
            order = [lmStudioV1, lmStudioV0, strataHealth, llamaProps, ollamaPS]
        }
        for probe in order {
            if Task.isCancelled { break }
            if let native = await probe() {
                info.merge(native)
                break
            }
        }
        return info
    }

    /// LM Studio 0.4+: unloads every loaded instance of the model, then loads it again with
    /// `contextLength`, and re-reads what the server actually applied. State-changing: call only
    /// after the user confirmed. Throws on any failure (the model may be left unloaded).
    ///
    /// The result's `model` is the id to chat with from now on. It differs from `model` when
    /// that was an instance id such as "key:2": the new instance gets the id the load response
    /// names (normally the key itself), and the old one no longer exists.
    public func reloadModel(_ model: String, contextLength: Int) async throws -> ModelContextInfo {
        guard let root = nativeAPIRoot else {
            throw ParleyError.api("This server does not offer a way to change the context length.")
        }
        guard contextLength > 0 else { throw ParleyError.api("The context length must be a positive number.") }

        let listing = try await requestJSON(Self.url(root, "api/v1/models"), method: "GET", body: nil, timeout: Self.probeTimeout)
        guard let current = Self.parseLMStudioV1(listing, model: model), let key = current.modelKey else {
            throw ParleyError.api("The server did not list \(model), so it cannot be reloaded.")
        }
        if let max = current.maxContextLength, contextLength > max {
            throw ParleyError.api("\(model) supports at most \(max) tokens of context.")
        }
        // Loading while an instance exists would add a second copy (double the memory).
        for id in current.instanceIDs {
            _ = try await requestJSON(Self.url(root, "api/v1/models/unload"), method: "POST",
                                      body: ["instance_id": id], timeout: Self.unloadTimeout)
        }
        let loaded = try await requestJSON(Self.url(root, "api/v1/models/load"), method: "POST",
                                           body: ["model": key, "context_length": contextLength, "echo_load_config": true],
                                           timeout: Self.loadTimeout)
        guard model != key else { return await fetchModelInfo(model: model) }
        let instance = ((loaded as? [String: Any])?["instance_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return await fetchModelInfo(model: instance ?? key)
    }

    // MARK: Requests

    static func url(_ root: URL, _ path: String) -> URL {
        var url = root
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    /// A read-only GET with a short timeout. Nil for any failure, a non-2xx status, a body
    /// that is not JSON, or a body with a top-level "error" (LM Studio answers unknown
    /// routes with HTTP 200 {"error":"Unexpected endpoint or method. …"}).
    func probeJSON(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.probeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        // The request timeout is an idle timeout; this bounds the whole exchange too.
        let body: Data? = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                guard let (data, response) = try? await self.session.data(for: request),
                      let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
                else { return nil }
                return data
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64((Self.probeTimeout + 1) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        if let dict = object as? [String: Any], Self.hasErrorKey(dict) { return nil }
        return object
    }

    /// A request whose failure the caller reports: non-2xx → ParleyError.http, an error body →
    /// ParleyError.api.
    private func requestJSON(_ url: URL, method: String, body: [String: Any]?, timeout: TimeInterval) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        applyAuthorization(to: &request)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ParleyError.http(status: status, body: Self.truncatedBody(data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ParleyError.api("The server's answer is not valid JSON.")
        }
        if let dict = object as? [String: Any], let error = dict["error"], !(error is NSNull) {
            throw ParleyError.api(ChunkParser.errorMessage(from: error))
        }
        return object
    }

    private static func hasErrorKey(_ dict: [String: Any]) -> Bool {
        if let error = dict["error"], !(error is NSNull) { return true }
        return (dict["object"] as? String) == "error"
    }

    // MARK: Parsers (pure, for tests)

    private static func int(_ any: Any?) -> Int? {
        guard let n = ChunkParser.intValue(any), n > 0 else { return nil }
        return n
    }

    /// GET {base}/models: context fields on the entry whose id is `model`, and the server kind
    /// its `owned_by` reveals. Nil when the entry is missing or says nothing useful.
    static func parseModelList(_ object: Any, model: String) -> ModelContextInfo? {
        guard let root = object as? [String: Any], let data = root["data"] as? [[String: Any]] else { return nil }
        let owners = Set(data.compactMap { $0["owned_by"] as? String })
        var info = ModelContextInfo(model: model)
        if owners == ["vllm"] { info.serverKind = .vLLM }
        else if owners == ["llamacpp"] { info.serverKind = .llamaCpp }
        // LM Studio's OpenAI-compatible list carries only {id, object, owned_by}.
        else if owners == ["organization_owner"] { info.serverKind = .lmStudio }
        // Strata's shared port. Its request body limit: 12 MiB for a native model (meta has gpus,
        // aliases), 4 MiB in the runtime mode (meta has gpuIds, context, mode).
        else if owners == ["strata"] {
            info.serverKind = .strata
            let metas = data.compactMap { $0["meta"] as? [String: Any] }
            let runtime = !metas.isEmpty && metas.allSatisfy { $0["mode"] != nil || $0["gpuIds"] != nil }
            info.maxRequestBytes = runtime ? strataRuntimeBodyLimit : strataShareBodyLimit
        }

        if let entry = data.first(where: { ($0["id"] as? String) == model }) {
            if let n = int(entry["max_model_len"]) {          // vLLM: fixed at server start
                info.loadedContextLength = n
                info.maxContextLength = n
                info.serverKind = .vLLM
            }
            if let meta = entry["meta"] as? [String: Any] {   // llama.cpp, Strata
                info.loadedContextLength = int(meta["n_ctx"]) ?? info.loadedContextLength
                info.maxContextLength = int(meta["n_ctx_train"]) ?? info.maxContextLength
                // Strata's shared port in its runtime mode (tokens).
                if info.serverKind == .strata {
                    info.loadedContextLength = info.loadedContextLength ?? int(meta["context"])
                }
            }
            // Strata's engine: status {value: "loaded"|"unloaded"} (llama.cpp router mode too).
            if let status = (entry["status"] as? [String: Any])?["value"] as? String {
                if status == "loaded" { info.isLoaded = true } else if status == "unloaded" { info.isLoaded = false }
            }
            // Strata's engine, OpenRouter: architecture.input_modalities.
            if let modalities = (entry["architecture"] as? [String: Any])?["input_modalities"] as? [String], !modalities.isEmpty {
                info.acceptsImages = modalities.contains("image")
            }
            // Hosted APIs: OpenRouter/Together context_length (+ top_provider), Groq context_window.
            let top = entry["top_provider"] as? [String: Any]
            if let n = int(entry["context_length"]) ?? int(top?["context_length"]) ?? int(entry["context_window"]) {
                info.loadedContextLength = info.loadedContextLength ?? n
            }
            if let n = int(entry["max_context_length"]) {      // Mistral (and LM Studio's native lists)
                info.maxContextLength = info.maxContextLength ?? n
            }
            if info.serverKind == nil, info.loadedContextLength != nil || info.maxContextLength != nil {
                info.serverKind = .hosted
            }
        }
        return info == ModelContextInfo(model: model) ? nil : info
    }

    /// LM Studio 0.4+ GET /api/v1/models: {"models":[{key, type, max_context_length,
    /// loaded_instances:[{id, config:{context_length,…}}]}]}. Nil when the shape does not match.
    static func parseLMStudioV1(_ object: Any, model: String) -> ModelContextInfo? {
        guard let root = object as? [String: Any], let models = root["models"] as? [[String: Any]],
              models.allSatisfy({ $0["key"] is String && $0["loaded_instances"] is [Any] }) else { return nil }
        var info = ModelContextInfo(model: model, serverKind: .lmStudio)
        func instances(_ entry: [String: Any]) -> [[String: Any]] {
            entry["loaded_instances"] as? [[String: Any]] ?? []
        }
        guard let entry = models.first(where: { ($0["key"] as? String) == model })
            ?? models.first(where: { instances($0).contains { ($0["id"] as? String) == model } }) else {
            return info   // LM Studio, but this model is not in its list
        }
        let loaded = instances(entry)
        let type = (entry["type"] as? String ?? "llm").lowercased()
        info.modelKey = entry["key"] as? String
        info.maxContextLength = int(entry["max_context_length"])
        info.instanceIDs = loaded.compactMap { $0["id"] as? String }
        info.isLoaded = !loaded.isEmpty
        let preferred = loaded.first { ($0["id"] as? String) == model } ?? loaded.first
        info.loadedContextLength = int((preferred?["config"] as? [String: Any])?["context_length"])
        info.canSetContextLength = !type.hasPrefix("embedding")
        return info
    }

    /// LM Studio before 0.4, GET /api/v0/models: {"data":[{id, state, max_context_length,
    /// loaded_context_length (only when loaded)}]}.
    static func parseLMStudioV0(_ object: Any, model: String) -> ModelContextInfo? {
        guard let root = object as? [String: Any], let data = root["data"] as? [[String: Any]],
              !data.isEmpty, data.allSatisfy({ $0["state"] is String }) else { return nil }
        var info = ModelContextInfo(model: model, serverKind: .lmStudio)
        guard let entry = data.first(where: { ($0["id"] as? String) == model }) else { return info }
        info.maxContextLength = int(entry["max_context_length"])
        let isLoaded = (entry["state"] as? String) == "loaded"
        info.isLoaded = isLoaded
        if isLoaded { info.loadedContextLength = int(entry["loaded_context_length"]) }
        return info
    }

    /// Strata's engine list: no owned_by anywhere, and entries with meta.n_ctx and a status object.
    /// (llama.cpp's router list has a status too, but says owned_by "llamacpp".)
    static func looksLikeStrataEngine(_ object: Any) -> Bool {
        guard let root = object as? [String: Any], let data = root["data"] as? [[String: Any]], !data.isEmpty,
              data.allSatisfy({ $0["owned_by"] == nil }) else { return false }
        return data.contains { entry in
            (entry["meta"] as? [String: Any])?["n_ctx"] != nil && entry["status"] is [String: Any]
        }
    }

    /// Strata's engine GET /health (no API key needed): {"status":"ok","max_context":N,"model":id,
    /// "images":bool,"loaded":bool,"service":"strata",…}. The context, images and loaded state
    /// describe the engine's current model, so they are used only when that is `model` (PolyStrata
    /// serves several models; the models list has each one's n_ctx).
    static func parseStrataHealth(_ object: Any, model: String) -> ModelContextInfo? {
        guard let root = object as? [String: Any], (root["service"] as? String) == "strata" else { return nil }
        var info = ModelContextInfo(model: model, serverKind: .strata)
        guard (root["model"] as? String) == model else { return info }
        info.loadedContextLength = int(root["max_context"])     // 0 while the engine starts
        info.acceptsImages = root["images"] as? Bool
        info.isLoaded = root["loaded"] as? Bool
        return info
    }

    /// llama.cpp GET /props: default_generation_settings.n_ctx is the per-request (per-slot) limit.
    static func parseLlamaCppProps(_ object: Any) -> ModelContextInfo? {
        guard let root = object as? [String: Any],
              let settings = root["default_generation_settings"] as? [String: Any],
              let n = int(settings["n_ctx"]) else { return nil }
        return ModelContextInfo(model: "", serverKind: .llamaCpp, loadedContextLength: n)
    }

    /// Ollama GET /api/ps: {"models":[{name, model, context_length, …}]} lists running models.
    static func parseOllamaPS(_ object: Any, model: String) -> ModelContextInfo? {
        guard let root = object as? [String: Any], let models = root["models"] as? [[String: Any]],
              models.allSatisfy({ $0["name"] is String && $0["key"] == nil }) else { return nil }
        // An empty list is ambiguous; every LM Studio-like list was already ruled out above.
        var info = ModelContextInfo(model: model, serverKind: .ollama, isLoaded: false)
        let names = [model, model + ":latest"]
        if let entry = models.first(where: { names.contains($0["name"] as? String ?? "") || names.contains($0["model"] as? String ?? "") }) {
            info.isLoaded = true
            info.loadedContextLength = int(entry["context_length"])
        }
        return info
    }
}
