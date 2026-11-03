import Foundation

// How full the context window is: which limit applies, and how many tokens the conversation
// uses. Pure functions, so the status bar's numbers are unit-tested.

public enum ContextLimitSource: String, Sendable, Hashable {
    /// The server reported the length it uses now (loaded instance, n_ctx, max_model_len, …).
    case server
    /// The user typed it in.
    case manual
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

    /// Precedence: what the server uses now > the user's own value > the model's maximum.
    public static func limit(info: ModelContextInfo?, manual: Int?) -> ContextLimit? {
        if let n = info?.loadedContextLength, n > 0 { return ContextLimit(tokens: n, source: .server) }
        if let n = manual, n > 0 { return ContextLimit(tokens: n, source: .manual) }
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

    /// What one message costs in a request: its text, text attachments and images (never reasoning,
    /// which is not sent back).
    public static func estimateTokens(message: Message) -> Int {
        var tokens = messageOverhead + estimateTokens(message.content)
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
    public static func usage(
        messages: [Message],
        systemPrompt: String,
        inFlightID: UUID? = nil,
        liveCompletionTokens: Int = 0,
        liveIsEstimated: Bool = false
    ) -> ContextUsage {
        var tokens = 0
        var estimated = false
        var start = messages.startIndex

        if let i = messages.lastIndex(where: { $0.id != inFlightID && $0.role == .assistant && counted($0) != nil }),
           let counted = counted(messages[i]) {
            tokens = counted
            start = messages.index(after: i)
        } else {
            let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty {
                tokens += messageOverhead + estimateTokens(system)
                estimated = true
            }
        }
        for message in messages[start...] where message.id != inFlightID {
            // Empty (failed) replies are not sent.
            if message.role == .assistant && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            tokens += estimateTokens(message: message)
            estimated = true
        }
        if liveCompletionTokens > 0 {
            tokens += liveCompletionTokens
            estimated = estimated || liveIsEstimated
        }
        return ContextUsage(tokens: tokens, isEstimated: estimated)
    }

    private static func counted(_ message: Message) -> Int? {
        guard let usage = message.usage else { return nil }
        let total: Int
        if let prompt = usage.promptTokens {
            total = prompt + (usage.completionTokens ?? 0)
        } else if let all = usage.totalTokens {
            total = all
        } else {
            return nil
        }
        return max(0, total - reasoningTokens(in: message))
    }

    /// The reply's thinking tokens, which the next request leaves out: the server's count, else
    /// (llama.cpp, LM Studio, Strata report none) an estimate from the streamed reasoning text,
    /// never more than the reply's completion tokens.
    static func reasoningTokens(in message: Message) -> Int {
        guard let usage = message.usage else { return 0 }
        if let reported = usage.reasoningTokens { return reported }
        guard let reasoning = message.reasoning, !reasoning.isEmpty else { return 0 }
        let estimate = estimateTokens(reasoning)
        if let completion = usage.completionTokens { return min(estimate, completion) }
        return estimate
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
