import Foundation

// How full the context window is: which limit applies, and how many tokens the conversation
// uses. Pure functions, so the status bar's numbers are unit-tested.

public enum ContextLimitSource: String, Sendable, Hashable {
    /// The server reported the length it uses now (loaded instance, n_ctx, max_model_len, …).
    case server
    /// The user typed it in.
    case manual
    /// Named by an earlier overflow error from the server (Strata, llama.cpp, vLLM, OpenAI).
    case learned
    /// Only the model's maximum is known; the loaded value may be smaller.
    case serverMaximum
}

public struct ContextLimit: Sendable, Hashable {
    public var tokens: Int
    public var source: ContextLimitSource

    public init(tokens: Int, source: ContextLimitSource) {
        self.tokens = tokens
        self.source = source
    }
}

public struct ContextUsage: Sendable, Hashable {
    public var tokens: Int
    /// True when any part was estimated from text rather than counted by the server.
    public var isEstimated: Bool

    public init(tokens: Int, isEstimated: Bool) {
        self.tokens = tokens
        self.isEstimated = isEstimated
    }

    /// Share of `limit` in percent (may exceed 100).
    public func percent(of limit: Int) -> Double {
        guard limit > 0 else { return 0 }
        return Double(tokens) / Double(limit) * 100
    }
}

public enum ContextBudget {
    /// Rough cost of one image (OpenAI high detail at 1024², similar to common local VLMs).
    public static let imageTokens = 768
    /// Chat-template tokens per message (role markers, separators).
    public static let messageOverhead = 4

    /// Precedence: what the server uses now > the user's own value > the value an overflow error
    /// named > the model's maximum.
    public static func limit(info: ModelContextInfo?, manual: Int?, learned: Int? = nil) -> ContextLimit? {
        if let n = info?.loadedContextLength, n > 0 { return ContextLimit(tokens: n, source: .server) }
        if let n = manual, n > 0 { return ContextLimit(tokens: n, source: .manual) }
        if let n = learned, n > 0 { return ContextLimit(tokens: n, source: .learned) }
        if let n = info?.maxContextLength, n > 0 { return ContextLimit(tokens: n, source: .serverMaximum) }
        return nil
    }

    /// Rough token count: CJK characters ≈ 1 token each, everything else ≈ 4 characters per token.
    public static func estimateTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        return cjk + (other + 3) / 4
    }

    /// What one tool definition costs in a request.
    public static func estimateTokens(tool: ChatTool) -> Int {
        var function: [String: JSONValue] = ["name": .string(tool.name), "parameters": tool.parameters]
        if let description = tool.description { function["description"] = .string(description) }
        return estimateTokens(JSONValue.object(function).sortedJSONText) + 8
    }

    /// What one tool round costs in a request: its text, then each call and its result.
    /// `resolvedOnly` leaves out calls still waiting for a result (the reply in flight).
    public static func estimateTokens(round: ToolRound, resolvedOnly: Bool = false) -> Int {
        var tokens = messageOverhead + estimateTokens(round.content)
        for call in round.calls where !resolvedOnly || call.result != nil {
            tokens += estimateTokens(call: call) + estimateResultTokens(call: call)
        }
        return tokens
    }

    private static func estimateTokens(call: ToolCallRecord) -> Int {
        8 + estimateTokens(call.name) + estimateTokens(call.replayArguments)
    }

    private static func estimateResultTokens(call: ToolCallRecord) -> Int {
        messageOverhead + estimateTokens(call.replayResult)
    }

    /// What one message costs in a request: its text, text attachments, images and tool rounds
    /// (never reasoning, which is not sent back).
    public static func estimateTokens(message: Message) -> Int {
        var tokens = 0
        let rounds = message.toolRounds ?? []
        // A reply that ended in a tool round has no final message.
        if rounds.isEmpty || !Message.isBlank(message.content) {
            tokens += messageOverhead + estimateTokens(message.content)
        }
        for round in rounds { tokens += estimateTokens(round: round) }
        guard message.role == .user else { return tokens }
        for attachment in message.attachments {
            switch attachment.kind {
            case .text:
                // Sent wrapped as <file name="…">…</file>.
                tokens += estimateTokens(attachment.text ?? "") + estimateTokens(attachment.filename) + 8
            case .image:
                tokens += attachment.data == nil ? 0 : imageTokens
            }
        }
        return tokens
    }

    /// Tokens the conversation occupies. Starts from the newest reply the server counted
    /// (prompt + completion, minus its reasoning, which is never sent back: the server's
    /// reasoning_tokens when it reports them, else an estimate from the reasoning text) and
    /// estimates only what came after it. Without any count, everything
    /// is estimated, system prompt included. `inFlightID` (the reply being streamed) is left
    /// out; its tokens so far are `liveCompletionTokens`.
    ///
    /// A message's `usage` is always its last request's, whose prompt holds the earlier rounds. A
    /// reply that has none (stopped or failed between rounds, or still in flight) anchors on its
    /// newest round that has one instead, plus estimates for what came after that request: this
    /// keeps the figure honest during a tool loop. `toolDefinitionTokens` are what the next request
    /// sends as `tools`: added in full without an anchor, otherwise only what the anchor's request
    /// did not already carry.
    public static func usage(
        messages: [Message],
        systemPrompt: String,
        inFlightID: UUID? = nil,
        liveCompletionTokens: Int = 0,
        liveIsEstimated: Bool = false,
        toolDefinitionTokens: Int = 0
    ) -> ContextUsage {
        var tokens = 0
        var estimated = false
        var start = messages.startIndex
        var anchored = false
        var anchorDefinitions = 0

        if let i = messages.lastIndex(where: { hasAnchor($0, inFlightID: inFlightID) }) {
            let message = messages[i]
            anchored = true
            anchorDefinitions = message.toolDefinitionTokens ?? 0
            start = messages.index(after: i)
            if message.id != inFlightID, let counted = counted(message) {
                tokens = counted
            } else if let anchor = roundAnchor(message, inFlight: message.id == inFlightID) {
                tokens = anchor
                estimated = true
            }
        } else {
            let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty {
                tokens += messageOverhead + estimateTokens(system)
                estimated = true
            }
        }
        for message in messages[start...] {
            let rounds = message.toolRounds ?? []
            if message.id == inFlightID {
                // Its finished rounds are part of the next request; its current text is live.
                for round in rounds {
                    tokens += estimateTokens(round: round, resolvedOnly: true)
                    estimated = true
                }
                continue
            }
            // Empty (failed) replies are not sent.
            if message.role == .assistant && rounds.isEmpty && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            tokens += estimateTokens(message: message)
            estimated = true
        }
        if liveCompletionTokens > 0 {
            tokens += liveCompletionTokens
            estimated = estimated || liveIsEstimated
        }
        let definitions = anchored ? max(0, toolDefinitionTokens - anchorDefinitions) : toolDefinitionTokens
        if definitions > 0 {
            tokens += definitions
            estimated = true
        }
        return ContextUsage(tokens: tokens, isEstimated: estimated)
    }

    private static func hasAnchor(_ message: Message, inFlightID: UUID?) -> Bool {
        guard message.role == .assistant else { return false }
        if message.id != inFlightID && counted(message) != nil { return true }
        return roundAnchor(message, inFlight: message.id == inFlightID) != nil
    }

    /// Tokens up to and including the newest round the server counted, its reasoning left out, plus
    /// estimates for that round's results, later rounds and any final text.
    private static func roundAnchor(_ message: Message, inFlight: Bool) -> Int? {
        let rounds = message.toolRounds ?? []
        guard let i = rounds.lastIndex(where: { countedTotal($0.usage) != nil }),
              let usage = rounds[i].usage, let total = countedTotal(usage) else { return nil }
        var tokens = max(0, total - reasoningTokens(usage: usage, reasoning: rounds[i].reasoning))
        for call in rounds[i].calls where !inFlight || call.result != nil {
            tokens += estimateResultTokens(call: call)
        }
        for round in rounds[(i + 1)...] { tokens += estimateTokens(round: round, resolvedOnly: inFlight) }
        if !inFlight, !Message.isBlank(message.content) {
            tokens += messageOverhead + estimateTokens(message.content)
        }
        return tokens
    }

    private static func counted(_ message: Message) -> Int? {
        guard let usage = message.usage, let total = countedTotal(usage) else { return nil }
        return max(0, total - reasoningTokens(in: message))
    }

    private static func countedTotal(_ usage: TokenUsage?) -> Int? {
        guard let usage else { return nil }
        if let prompt = usage.promptTokens { return prompt + (usage.completionTokens ?? 0) }
        return usage.totalTokens
    }

    /// The reply's thinking tokens, which the next request leaves out: the server's count, else
    /// (llama.cpp, LM Studio, Strata report none) an estimate from the streamed reasoning text,
    /// never more than the reply's completion tokens.
    static func reasoningTokens(in message: Message) -> Int {
        guard let usage = message.usage else { return 0 }
        return reasoningTokens(usage: usage, reasoning: message.reasoning)
    }

    private static func reasoningTokens(usage: TokenUsage, reasoning: String?) -> Int {
        if let reported = usage.reasoningTokens { return reported }
        guard let reasoning, !reasoning.isEmpty else { return 0 }
        let estimate = estimateTokens(reasoning)
        if let completion = usage.completionTokens { return min(estimate, completion) }
        return estimate
    }

    /// The most characters a tool result may hand the model: the configured cap, within half the
    /// room left at about 4 characters per token, so one result does not end a small context with
    /// an overflow error. Never below 2,000, or a nearly full context would get nothing useful.
    public static func toolResultBudget(configured: Int, limit: ContextLimit?, used: Int) -> Int {
        guard let limit else { return configured }
        return min(configured, max(2_000, (limit.tokens - used) * 2))
    }

    /// The context size named in an overflow error, if any:
    /// llama.cpp `"n_ctx": M` / "available context size (M tokens)", vLLM and OpenAI
    /// "maximum context length is M tokens", Strata "exceeds the context window: … the context (M)".
    public static func contextLength(fromError text: String) -> Int? {
        let patterns = [
            #""n_ctx"\s*:\s*(\d+)"#,
            #"available context size \((\d+) tokens\)"#,
            #"maximum context length is (\d+) tokens"#,
            #"exceeds the context window:.*?the context \((\d+)\)"#,
        ]
        for pattern in patterns {
            if let n = firstNumber(pattern, in: text) { return n }
        }
        return nil
    }

    /// Strata's context overflow (HTTP 400 invalid_request_error), parsed:
    ///  - "request exceeds the context window: prompt (P tokens) leaves no room to answer in the
    ///    context (C); requests are never truncated"
    ///  - with fit_max_tokens off: "… prompt (P tokens) + max tokens (M) exceeds the context (C);
    ///    … Send a smaller max_tokens (at most R here), or …"
    public struct Overflow: Sendable, Equatable {
        public var promptTokens: Int?
        public var contextLength: Int
        /// Set when the request's max_tokens (not the prompt alone) made it overflow.
        public var maxTokens: Int?
        /// The largest max_tokens that would have fit.
        public var room: Int?
    }

    public static func strataOverflow(fromError text: String) -> Overflow? {
        guard text.contains("exceeds the context window"),
              let context = firstNumber(#"the context \((\d+)\)"#, in: text) else { return nil }
        return Overflow(
            promptTokens: firstNumber(#"prompt \((\d+) tokens\)"#, in: text),
            contextLength: context,
            maxTokens: firstNumber(#"max tokens \((\d+)\)"#, in: text),
            room: firstNumber(#"at most (\d+) here"#, in: text, allowZero: true)
        )
    }

    private static func firstNumber(_ pattern: String, in text: String, allowZero: Bool = false) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let n = Int(text[range]), n > 0 || (allowZero && n == 0) else { return nil }
        return n
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF,   // Fullwidth forms
             0x20000...0x2FA1F: // Extensions B–F, compatibility supplement
            return true
        default:
            return false
        }
    }
}
