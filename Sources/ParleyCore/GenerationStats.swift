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

    public init(
        tokensPerSecond: Double? = nil,
        completionTokens: Int? = nil,
        timeToFirstToken: Double? = nil,
        generationDuration: Double? = nil,
        isEstimated: Bool? = nil
    ) {
        self.tokensPerSecond = tokensPerSecond
        self.completionTokens = completionTokens
        self.timeToFirstToken = timeToFirstToken
        self.generationDuration = generationDuration
        self.isEstimated = isEstimated
    }
}

/// llama.cpp's `timings` object (last chunk of every stream; every chunk with timings_per_token).
public struct ServerTimings: Sendable, Equatable {
    public var promptTokens: Int?
    public var promptMilliseconds: Double?
    public var cachedTokens: Int?
    public var predictedTokens: Int?
    public var predictedMilliseconds: Double?
    public var predictedPerSecond: Double?

    public init(
        promptTokens: Int? = nil,
        promptMilliseconds: Double? = nil,
        cachedTokens: Int? = nil,
        predictedTokens: Int? = nil,
        predictedMilliseconds: Double? = nil,
        predictedPerSecond: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.promptMilliseconds = promptMilliseconds
        self.cachedTokens = cachedTokens
        self.predictedTokens = predictedTokens
        self.predictedMilliseconds = predictedMilliseconds
        self.predictedPerSecond = predictedPerSecond
    }

    var isEmpty: Bool {
        promptTokens == nil && promptMilliseconds == nil && cachedTokens == nil
            && predictedTokens == nil && predictedMilliseconds == nil && predictedPerSecond == nil
    }
}

/// Measures generation speed on the client. Works with every OpenAI-compatible server: each
/// stream chunk that carries reasoning or content counts as one token (true for llama.cpp,
/// LM Studio, vLLM and OpenAI in practice) until the server reports an exact count in `usage`
/// or llama.cpp `timings`.
public struct GenerationMeter: Sendable {
    public private(set) var requestStartedAt: Date?
    public private(set) var firstTokenAt: Date?
    public private(set) var lastTokenAt: Date?
    /// Chunks that carried non-empty reasoning or content.
    public private(set) var chunkCount = 0
    /// Of those, chunks that carried reasoning.
    public private(set) var reasoningChunkCount = 0
    /// usage.completion_tokens, once the server sent it.
    public private(set) var reportedCompletionTokens: Int?
    /// usage.completion_tokens_details.reasoning_tokens, once the server sent it.
    public private(set) var reportedReasoningTokens: Int?
    public private(set) var timings: ServerTimings?

    /// Below this, a rate is mostly noise from chunk timing.
    static let minimumDuration: Double = 0.05

    public init(requestStartedAt: Date? = nil) {
        self.requestStartedAt = requestStartedAt
    }

    public mutating func record(_ delta: ChatDelta, now: Date = Date()) {
        // The opening {"role":"assistant","content":""} chunk is not a token.
        let hasReasoning = !(delta.reasoning ?? "").isEmpty
        if !(delta.content ?? "").isEmpty || hasReasoning {
            chunkCount += 1
            if hasReasoning { reasoningChunkCount += 1 }
            if firstTokenAt == nil { firstTokenAt = now }
            lastTokenAt = now
        }
        if let n = delta.usage?.completionTokens { reportedCompletionTokens = n }
        if let n = delta.usage?.reasoningTokens { reportedReasoningTokens = n }
        if let t = delta.timings { timings = t }
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
            isEstimated: isEstimated
        )
    }
}
