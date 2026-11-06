import Foundation

// Generation speed: what is stored on a finished reply (GenerationStats), the timing block
// llama.cpp appends to its last stream chunk (ServerTimings), and the client-side meter that
// measures tokens per second while a reply streams (GenerationMeter).

/// Speed of one assistant reply. Every field is optional, so the struct can grow without
/// breaking files that were written by an older version.
public struct GenerationStats: Codable, Hashable, Sendable {
    /// Generated tokens (reasoning + content) per second, from the first token to the last.
    /// Reasoning the server counted but never streamed (OpenAI o-series and similar) is left
    /// out: it was generated before the first visible token, outside the measured span.
    public var tokensPerSecond: Double?
    /// Generated tokens: the server's count when it reported one, else the number of chunks.
    public var completionTokens: Int?
    /// Seconds from sending the request to the first streamed token (includes prompt processing,
    /// and any reasoning the server does not stream).
    public var timeToFirstToken: Double?
    /// Seconds from the first generated token to the last.
    public var generationDuration: Double?
    /// True when the counts come from stream chunks (one chunk ≈ one token), not from the server.
    public var isEstimated: Bool?
    /// Why the server ended the reply ("stop", "length", …), when it said so. "length" means the
    /// reply hit max_tokens or the end of the context.
    public var finishReason: String?
    /// Prompt tokens the server actually read for this reply (llama.cpp / Strata timings.prompt_n;
    /// the cached part is not included).
    public var promptTokensRead: Int?
    /// How fast the server read the prompt (timings.prompt_per_second).
    public var promptTokensPerSecond: Double?
    /// Prompt tokens reused from the server's cache (timings.cache_n, or
    /// usage.prompt_tokens_details.cached_tokens).
    public var cachedPromptTokens: Int?

    public init(
        tokensPerSecond: Double? = nil,
        completionTokens: Int? = nil,
        timeToFirstToken: Double? = nil,
        generationDuration: Double? = nil,
        isEstimated: Bool? = nil,
        finishReason: String? = nil,
        promptTokensRead: Int? = nil,
        promptTokensPerSecond: Double? = nil,
        cachedPromptTokens: Int? = nil
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.completionTokens = completionTokens
        self.timeToFirstToken = timeToFirstToken
        self.generationDuration = generationDuration
        self.isEstimated = isEstimated
        self.finishReason = finishReason
        self.promptTokensRead = promptTokensRead
        self.promptTokensPerSecond = promptTokensPerSecond
        self.cachedPromptTokens = cachedPromptTokens
    }
}

/// llama.cpp's (and Strata's) `prompt_progress`: how far the server has read the prompt. Sent
/// before the first token, only when the request asked with `return_progress: true`.
public struct PromptProgress: Sendable, Equatable {
    /// Prompt tokens in all.
    public var total: Int
    /// Of those, reused from the server's cache (not read again).
    public var cached: Int
    /// Read so far, counted from token 0 (the cached part included).
    public var processed: Int
    /// Milliseconds since reading started.
    public var milliseconds: Int?

    public init(total: Int, cached: Int = 0, processed: Int, milliseconds: Int? = nil) {
        self.total = total
        self.cached = cached
        self.processed = processed
        self.milliseconds = milliseconds
    }

    /// The share of the work done, 0…1: the cached prefix does not count (llama.cpp's rule,
    /// (processed − cache) / (total − cache)).
    public var fraction: Double {
        let work = total - cached
        guard work > 0 else { return 1 }
        return min(1, max(0, Double(processed - cached) / Double(work)))
    }
}

/// llama.cpp's `timings` object (last chunk of every stream; every chunk with timings_per_token).
/// Strata sends the same object on its last chunk.
public struct ServerTimings: Sendable, Equatable {
    public var promptTokens: Int?
    public var promptMilliseconds: Double?
    public var cachedTokens: Int?
    public var predictedTokens: Int?
    public var predictedMilliseconds: Double?
    public var predictedPerSecond: Double?
    public var promptPerSecond: Double?

    public init(
        promptTokens: Int? = nil,
        promptMilliseconds: Double? = nil,
        cachedTokens: Int? = nil,
        predictedTokens: Int? = nil,
        predictedMilliseconds: Double? = nil,
        predictedPerSecond: Double? = nil,
        promptPerSecond: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.promptMilliseconds = promptMilliseconds
        self.cachedTokens = cachedTokens
        self.predictedTokens = predictedTokens
        self.predictedMilliseconds = predictedMilliseconds
        self.predictedPerSecond = predictedPerSecond
        self.promptPerSecond = promptPerSecond
    }

    var isEmpty: Bool {
        promptTokens == nil && promptMilliseconds == nil && cachedTokens == nil
            && predictedTokens == nil && predictedMilliseconds == nil && predictedPerSecond == nil
            && promptPerSecond == nil
    }

    /// prompt_per_second, else prompt_n / prompt_ms.
    var promptRate: Double? {
        if let r = promptPerSecond, r > 0, r.isFinite { return r }
        guard let n = promptTokens, n > 0, let ms = promptMilliseconds, ms > 0 else { return nil }
        return Double(n) / (ms / 1000)
    }
}

/// Measures generation speed on the client. Works with every OpenAI-compatible server: each
/// stream chunk that carries reasoning, content or a tool-call fragment counts as one token (true for llama.cpp,
/// LM Studio, vLLM and OpenAI in practice) until the server reports an exact count in `usage`
/// or llama.cpp `timings`.
public struct GenerationMeter: Sendable {
    public private(set) var requestStartedAt: Date?
    public private(set) var firstTokenAt: Date?
    public private(set) var lastTokenAt: Date?
    /// Chunks that carried non-empty reasoning, content or a tool-call fragment.
    public private(set) var chunkCount = 0
    /// Of those, chunks that carried reasoning.
    public private(set) var reasoningChunkCount = 0
    /// usage.completion_tokens, once the server sent it.
    public private(set) var reportedCompletionTokens: Int?
    /// usage.completion_tokens_details.reasoning_tokens, once the server sent it.
    public private(set) var reportedReasoningTokens: Int?
    /// usage.prompt_tokens_details.cached_tokens, once the server sent it.
    public private(set) var reportedCachedPromptTokens: Int?
    public private(set) var timings: ServerTimings?
    public private(set) var finishReason: String?
    /// The latest prompt_progress, until the first token arrives.
    public private(set) var promptProgress: PromptProgress?

    /// Below this, a rate is mostly noise from chunk timing.
    static let minimumDuration: Double = 0.05

    public init(requestStartedAt: Date? = nil) {
        self.requestStartedAt = requestStartedAt
    }

    public mutating func record(_ delta: ChatDelta, now: Date = Date()) {
        // The opening {"role":"assistant","content":""} chunk is not a token.
        let hasReasoning = !(delta.reasoning ?? "").isEmpty
        if !(delta.content ?? "").isEmpty || hasReasoning || !delta.toolCalls.isEmpty {
            chunkCount += 1
            if hasReasoning { reasoningChunkCount += 1 }
            if firstTokenAt == nil { firstTokenAt = now }
            lastTokenAt = now
            promptProgress = nil
        }
        if let n = delta.usage?.completionTokens { reportedCompletionTokens = n }
        if let n = delta.usage?.reasoningTokens { reportedReasoningTokens = n }
        if let n = delta.usage?.cachedPromptTokens { reportedCachedPromptTokens = n }
        if let t = delta.timings { timings = t }
        if let f = delta.finishReason { finishReason = f }
        if let p = delta.promptProgress, firstTokenAt == nil { promptProgress = p }
    }

    /// Exact when the server counted, else the chunk count.
    public var generatedTokens: Int {
        timings?.predictedTokens ?? reportedCompletionTokens ?? chunkCount
    }

    public var isEstimated: Bool {
        timings?.predictedTokens == nil && reportedCompletionTokens == nil
    }

    public var timeToFirstToken: Double? {
        guard let start = requestStartedAt, let first = firstTokenAt else { return nil }
        return max(0, first.timeIntervalSince(start))
    }

    /// Tokens generated within the measured span: the server's count minus reasoning it
    /// counted but never streamed (no reasoning chunk arrived), which happened before it.
    var streamedTokens: Int {
        guard timings?.predictedTokens == nil, let reported = reportedCompletionTokens,
              reasoningChunkCount == 0, let hidden = reportedReasoningTokens, hidden > 0,
              // Reasoning sent inline as <think> content arrives as content chunks: not hidden.
              chunkCount <= reported - hidden else { return generatedTokens }
        return max(0, reported - hidden)
    }

    /// Tokens after the first one, divided by the time since the first one. Nil until there is
    /// enough to measure.
    public var tokensPerSecond: Double? {
        if let server = timings?.predictedPerSecond, server > 0, server.isFinite { return server }
        guard let first = firstTokenAt, let last = lastTokenAt else { return nil }
        let duration = last.timeIntervalSince(first)
        let tokens = streamedTokens
        guard tokens >= 2, duration >= Self.minimumDuration else { return nil }
        return Double(tokens - 1) / duration
    }

    /// What is stored on the finished message. Nil when nothing was generated.
    public func finalStats() -> GenerationStats? {
        guard let first = firstTokenAt, let last = lastTokenAt else { return nil }
        let duration: Double
        if let ms = timings?.predictedMilliseconds, ms > 0 {
            duration = ms / 1000
        } else {
            duration = max(0, last.timeIntervalSince(first))
        }
        return GenerationStats(
            tokensPerSecond: tokensPerSecond,
            completionTokens: generatedTokens,
            timeToFirstToken: timeToFirstToken,
            generationDuration: duration,
            isEstimated: isEstimated,
            finishReason: finishReason,
            promptTokensRead: timings?.promptTokens,
            promptTokensPerSecond: timings?.promptRate,
            cachedPromptTokens: timings?.cachedTokens ?? reportedCachedPromptTokens
        )
    }
}
