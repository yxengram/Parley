import Foundation

// Streaming primitives for OpenAI-compatible chat completions:
//  - SSEDecoder turns server-sent-event lines into data payloads,
//  - ChunkParser turns one payload into a ChatDelta,
//  - StreamAccumulator folds deltas into displayable content and reasoning,
//    splitting inline <think>...</think> blocks out of the content.
// Nothing in here logs or retains message content beyond the values it returns.

public struct ChatDelta: Sendable, Equatable {
    public var content: String?
    /// From delta.reasoning_content OR delta.reasoning.
    public var reasoning: String?
    public var usage: TokenUsage?
    public var finishReason: String?

    public init(content: String? = nil, reasoning: String? = nil, usage: TokenUsage? = nil, finishReason: String? = nil) {
        self.content = content
        self.reasoning = reasoning
        self.usage = usage
        self.finishReason = finishReason
    }
}

// MARK: - SSEDecoder

/// Splits an SSE byte stream's lines into JSON payload strings.
public struct SSEDecoder {
    private var dataLines: [String] = []
    /// The current event's type ("event:" field), applied to the next dispatched payload.
    private var eventType: String?

    public init() {}

    /// Feed one line, without its newline. Returns 0..n complete data payloads. "[DONE]" is returned verbatim.
    /// Handles "data:" with or without a space, ignores ":" comments, "id:" and "retry:".
    /// Spec-compliant: multiple data lines join with "\n" until a blank line. Because URLSession's
    /// AsyncBytes.lines drops blank lines, a data line whose accumulated buffer already parses as
    /// complete JSON is also emitted immediately.
    ///
    /// Errors that servers send outside a plain `data: {"error":...}` payload are normalized to
    /// that shape, so ChunkParser raises them: an `error:` field (llama.cpp), the data of an
    /// `event: error` event, and a bare JSON line with no field name.
    public mutating func feed(line rawLine: String) -> [String] {
        var line = Substring(rawLine)
        while line.last == "\r" || line.last == "\n" { line = line.dropLast() }

        // Blank line: end of event, dispatch whatever is buffered.
        if line.isEmpty {
            let out = flush()
            eventType = nil
            return out
        }
        // Comment line.
        if line.first == ":" {
            return []
        }

        // A bare JSON object line (no field name) is not valid SSE, but some servers send their
        // error body that way inside a 200 event stream. Treat it as data.
        if line.first == "{", dataLines.isEmpty, Self.isCompletePayload(String(line)) {
            return [dispatch(String(line))]
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data":
            break
        case "event":
            eventType = String(value)
            return []
        case "error":
            var out = flush()
            out.append(Self.errorPayload(String(value)))
            eventType = nil
            return out
        default:
            // "id", "retry" and unknown fields carry nothing we need.
            return []
        }

        var out: [String] = []
        let piece = String(value)

        // If something incomplete is buffered and this line is a complete payload on its own,
        // the blank line that should have separated them was most likely dropped. Emit the
        // stale buffer as its own payload rather than gluing the two together.
        if !dataLines.isEmpty, !Self.isCompletePayload(dataLines.joined(separator: "\n")), Self.isCompletePayload(piece) {
            out.append(contentsOf: flush())
        }

        dataLines.append(piece)
        let joined = dataLines.joined(separator: "\n")
        if Self.isCompletePayload(joined) {
            dataLines.removeAll(keepingCapacity: true)
            out.append(dispatch(joined))
        }
        return out
    }

    /// Flush the remaining buffer.
    public mutating func finish() -> [String] {
        let out = flush()
        eventType = nil
        return out
    }

    private mutating func flush() -> [String] {
        guard !dataLines.isEmpty else { return [] }
        let joined = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return [dispatch(joined)]
    }

    /// Applies the pending event type to one payload. The type is consumed here (not only at a
    /// blank line), because dropped blank lines would otherwise leak it into the next event.
    private mutating func dispatch(_ payload: String) -> String {
        defer { eventType = nil }
        guard eventType == "error",
              payload.trimmingCharacters(in: .whitespacesAndNewlines) != "[DONE]" else { return payload }
        return Self.errorPayload(payload)
    }

    /// Normalizes an error value to `{"error": {...}}`. A JSON object that already has an
    /// "error" key is kept; another object becomes the error; anything else is its message.
    static func errorPayload(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        let error: Any
        if let dict = parsed as? [String: Any] {
            if let inner = dict["error"], !(inner is NSNull) { return trimmed }
            error = dict
        } else if let s = parsed as? String, !s.isEmpty {
            error = ["message": s]
        } else if !trimmed.isEmpty {
            error = ["message": trimmed]
        } else {
            error = ["message": "The server reported an error."]
        }
        guard JSONSerialization.isValidJSONObject(["error": error]),
              let data = try? JSONSerialization.data(withJSONObject: ["error": error]) else {
            return #"{"error":{"message":"The server reported an error."}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// "[DONE]" or a complete top-level JSON object/array.
    private static func isCompletePayload(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return true }
        guard let first = trimmed.first, first == "{" || first == "[",
              let last = trimmed.last, last == "}" || last == "]" else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

// MARK: - ChunkParser

public enum ChunkParser {
    /// Parses one chat.completion.chunk JSON payload. Throws ParleyError.api(message) if the payload is {"error":{...}}.
    /// Returns nil for "[DONE]", non-JSON payloads and chunks that carry nothing useful.
    public static func parse(_ payload: String) throws -> ChatDelta? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[DONE]" { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }

        if let error = root["error"], !(error is NSNull) {
            throw ParleyError.api(errorMessage(from: error))
        }
        // vLLM / FastChat style: {"object":"error","message":...}
        if (root["object"] as? String) == "error" {
            throw ParleyError.api(errorMessage(from: root))
        }

        var delta = ChatDelta()

        if let choices = root["choices"] as? [[String: Any]], let choice = choices.first {
            // Streaming chunks carry "delta"; a non-streaming completion carries "message".
            let body = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any])
            if let body {
                delta.content = body["content"] as? String
                let reasoningContent = body["reasoning_content"] as? String
                let reasoning = body["reasoning"] as? String
                // Some servers send both with the same text; take one so nothing is duplicated.
                if let rc = reasoningContent, !rc.isEmpty {
                    delta.reasoning = rc
                } else if let r = reasoning, !r.isEmpty {
                    delta.reasoning = r
                } else {
                    delta.reasoning = reasoningContent ?? reasoning
                }
            }
            delta.finishReason = choice["finish_reason"] as? String
        }

        if let usage = root["usage"] as? [String: Any] {
            let parsed = TokenUsage(
                promptTokens: intValue(usage["prompt_tokens"]),
                completionTokens: intValue(usage["completion_tokens"]),
                totalTokens: intValue(usage["total_tokens"])
            )
            if parsed.promptTokens != nil || parsed.completionTokens != nil || parsed.totalTokens != nil {
                delta.usage = parsed
            }
        }

        if delta.content == nil, delta.reasoning == nil, delta.usage == nil, delta.finishReason == nil {
            return nil
        }
        return delta
    }

    private static func errorMessage(from error: Any) -> String {
        if let dict = error as? [String: Any] {
            if let message = dict["message"] as? String, !message.isEmpty { return message }
            if let code = dict["code"] { return "error \(code)" }
            if let type = dict["type"] as? String { return type }
            return "Unknown error"
        }
        if let s = error as? String, !s.isEmpty { return s }
        return "Unknown error"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - StreamAccumulator

/// Accumulates deltas into displayable content/reasoning. Handles inline <think>...</think>
/// split across chunk boundaries, and output containing only a closing </think>
/// (prompt template opened the tag): everything before it is reclassified as reasoning.
public struct StreamAccumulator: Sendable {
    public private(set) var content: String = ""
    public private(set) var reasoning: String = ""
    public private(set) var usage: TokenUsage?
    public private(set) var finishReason: String?
    public private(set) var reasoningStartedAt: Date?
    /// Set when the first content token after reasoning arrives, or at finish.
    public private(set) var reasoningEndedAt: Date?

    /// Inside an inline <think> block.
    private var inThinkTag = false
    /// Any opening tag has been seen in this stream.
    private var sawOpenTag = false
    /// Held-back text that may be the start of a tag.
    private var pending = ""
    /// Strip leading newlines from the next content (after a closing tag).
    private var trimNextContent = false
    /// When the first visible content arrived (for orphan </think> timing).
    private var firstContentAt: Date?

    private static let openTags = ["<think>", "<thinking>"]
    private static let closeTags = ["</think>", "</thinking>"]
    private static let allTags = openTags + closeTags

    /// True while currently inside reasoning.
    public var isReasoning: Bool {
        inThinkTag || (reasoningStartedAt != nil && reasoningEndedAt == nil)
    }

    public var reasoningDuration: Double? {
        guard let start = reasoningStartedAt, let end = reasoningEndedAt else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    public init() {}

    public mutating func apply(_ delta: ChatDelta, now: Date = Date()) {
        if let r = delta.reasoning, !r.isEmpty {
            appendReasoning(r, now: now)
        }
        if let c = delta.content, !c.isEmpty {
            processContent(c, now: now)
        }
        if let u = delta.usage {
            usage = u
        }
        if let f = delta.finishReason {
            finishReason = f
        }
    }

    /// Flushes any held-back partial tag text.
    public mutating func finish(now: Date = Date()) {
        if !pending.isEmpty {
            let text = pending
            pending = ""
            if inThinkTag {
                appendReasoning(text, now: now)
            } else {
                appendContent(text, now: now)
            }
        }
        inThinkTag = false
        if reasoningStartedAt != nil, reasoningEndedAt == nil {
            reasoningEndedAt = now
        }
    }

    // MARK: Private

    private mutating func processContent(_ text: String, now: Date) {
        var buffer = pending + text
        pending = ""

        while !buffer.isEmpty {
            if inThinkTag {
                if let (range, _) = Self.earliest(of: Self.closeTags, in: buffer) {
                    appendReasoning(String(buffer[..<range.lowerBound]), now: now)
                    inThinkTag = false
                    trimNextContent = true
                    buffer = String(buffer[range.upperBound...])
                    continue
                }
                let hold = Self.partialTagSuffixLength(buffer, tags: Self.closeTags)
                let split = buffer.index(buffer.endIndex, offsetBy: -hold)
                appendReasoning(String(buffer[..<split]), now: now)
                pending = String(buffer[split...])
                return
            }

            let tags = sawOpenTag ? Self.openTags : Self.allTags
            if let (range, tag) = Self.earliest(of: tags, in: buffer) {
                let before = String(buffer[..<range.lowerBound])
                buffer = String(buffer[range.upperBound...])
                if Self.openTags.contains(tag) {
                    appendContent(before, now: now)
                    inThinkTag = true
                    sawOpenTag = true
                    if reasoningStartedAt == nil { reasoningStartedAt = now }
                    reasoningEndedAt = nil
                } else {
                    // Orphan closing tag: the prompt template opened the block, so everything
                    // shown as content so far was really reasoning.
                    reclassifyContentAsReasoning(adding: before, now: now)
                    sawOpenTag = true
                    trimNextContent = true
                }
                continue
            }

            let hold = Self.partialTagSuffixLength(buffer, tags: tags)
            let split = buffer.index(buffer.endIndex, offsetBy: -hold)
            appendContent(String(buffer[..<split]), now: now)
            pending = String(buffer[split...])
            return
        }
    }

    private mutating func reclassifyContentAsReasoning(adding extra: String, now: Date) {
        let moved = content + extra
        content = ""
        if reasoningStartedAt == nil {
            reasoningStartedAt = firstContentAt ?? now
        }
        if !moved.isEmpty {
            if reasoning.isEmpty {
                reasoning = Self.trimmingLeadingNewlines(moved)
            } else {
                reasoning += moved
            }
        }
        firstContentAt = nil
        // Reasoning is over; the end is stamped when the first real content arrives (or at finish).
        reasoningEndedAt = nil
    }

    private mutating func appendReasoning(_ text: String, now: Date) {
        guard !text.isEmpty else { return }
        var piece = text
        if reasoning.isEmpty {
            piece = Self.trimmingLeadingNewlines(piece)
            if piece.isEmpty { return }
        }
        if reasoningStartedAt == nil { reasoningStartedAt = now }
        // Reasoning that resumes after content extends the reasoning phase.
        reasoningEndedAt = nil
        reasoning += piece
    }

    private mutating func appendContent(_ text: String, now: Date) {
        guard !text.isEmpty else { return }
        var piece = text
        if trimNextContent || (content.isEmpty && !reasoning.isEmpty) {
            piece = Self.trimmingLeadingNewlines(piece)
            if piece.isEmpty { return }
        }
        trimNextContent = false
        content += piece
        if firstContentAt == nil { firstContentAt = now }
        if reasoningStartedAt != nil, reasoningEndedAt == nil, !inThinkTag {
            reasoningEndedAt = now
        }
    }

    private static func trimmingLeadingNewlines(_ s: String) -> String {
        String(s.drop(while: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }))
    }

    /// The earliest occurrence of any of `tags` in `s`.
    private static func earliest(of tags: [String], in s: String) -> (Range<String.Index>, String)? {
        var best: (Range<String.Index>, String)?
        for tag in tags {
            if let r = s.range(of: tag, options: .literal) {
                if best == nil || r.lowerBound < best!.0.lowerBound {
                    best = (r, tag)
                }
            }
        }
        return best
    }

    /// Length (in Characters) of the longest suffix of `s` that is a proper prefix of one of `tags`.
    private static func partialTagSuffixLength(_ s: String, tags: [String]) -> Int {
        let maxLen = (tags.map(\.count).max() ?? 1) - 1
        let chars = Array(s.suffix(maxLen))
        var k = chars.count
        while k > 0 {
            let suffix = String(chars[(chars.count - k)...])
            if tags.contains(where: { $0.count > k && $0.hasPrefix(suffix) }) {
                return k
            }
            k -= 1
        }
        return 0
    }
}
