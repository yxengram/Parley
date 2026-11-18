import Foundation

// Context compaction: the earlier part of a conversation stands in a request as a summary the
// conversation's own model wrote, and only the messages after it are sent in full. Nothing is
// deleted: the messages stay in the file and on screen, `Conversation.compaction` says where the
// summary ends, and clearing it sends the whole history again.
//
// Every place that needs "what the next request carries" asks `Conversation.effectiveHistory`:
// the request itself, the context strip, and the composer's size check. With no compaction it is
// exactly `messages` and the system prompt, so requests are byte-for-byte what they were.

/// The summary of `messages[0...throughMessageID]`. Optional on `Conversation`, so a file without
/// it is unchanged and an older Parley, which ignores it, sends the whole history.
public struct ConversationCompaction: Codable, Hashable, Sendable {
    /// What the model wrote. Model-facing; shown in a disclosure at the boundary.
    public var summary: String
    /// The last message the summary covers. An id, not an index: a rollback or an edit before it
    /// removes it, and the compaction goes with it (`Conversation.truncate`).
    public var throughMessageID: UUID
    /// The last message that existed when the summary was made. A server's token count on a reply
    /// up to here describes a prompt with the full history, so the context strip does not start
    /// from it (`ContextBudget.usage(anchorsFrom:)`).
    public var countsStaleThroughID: UUID?
    public var createdAt: Date
    /// The model that wrote the summary.
    public var model: String?
    /// How many messages it covers, for the popover and the divider.
    public var messageCount: Int?

    public init(summary: String, throughMessageID: UUID, countsStaleThroughID: UUID? = nil, createdAt: Date = Date(),
                model: String? = nil, messageCount: Int? = nil) {
        self.summary = summary
        self.throughMessageID = throughMessageID
        self.countsStaleThroughID = countsStaleThroughID
        self.createdAt = createdAt
        self.model = model
        self.messageCount = messageCount
    }
}

/// What the next request carries: the messages after the summary, and the summary to add to the
/// system text. With no compaction, `messages` is the whole history and `summaryBlock` is nil.
public struct EffectiveHistory: Sendable {
    public var messages: [Message]
    /// Added to the system text, after the system prompt and any ReAct block
    /// (`ChatRequestOptions.historySummary`).
    public var summaryBlock: String?
    /// Index into `messages` from which a server's token count may anchor the context estimate.
    public var anchorsFrom: Int
    /// How many leading messages of the conversation the summary stands for.
    public var coveredCount: Int

    /// The system text the context estimate counts: the prompt and the summary.
    public func systemText(prompt: String) -> String {
        guard let summaryBlock else { return prompt }
        return Message.isBlank(prompt) ? summaryBlock : prompt + "\n\n" + summaryBlock
    }
}

public enum Compaction {
    /// The automatic threshold's default and range, in percent of the context length.
    public static let defaultThresholdPercent = 80
    public static let thresholdRange = 30...95
    /// What the summary request may write.
    public static let summaryMaxTokens = 2048
    /// The newest messages are always sent in full: at least the last user turn and what follows,
    /// and up to this share of the context length.
    public static let keptShare = 0.25

    /// The summary as the system text carries it. Model-facing, so English, marked as data.
    public static func block(_ summary: String) -> String {
        "<conversation_summary>\nThe earlier part of this conversation was summarized to save space. This summary "
            + "stands for those messages; the messages after it continue from where it ends.\n\n"
            + summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n</conversation_summary>"
    }

    /// True when automatic compaction should run before the next request: the context length is
    /// known, the estimate has reached `thresholdPercent` of it, and there is something to summarize.
    public static func isDue(usage: ContextUsage, limit: ContextLimit?, thresholdPercent: Int) -> Bool {
        guard let limit, limit.tokens > 0 else { return false }
        return Double(usage.tokens) >= Double(limit.tokens) * Double(thresholdPercent) / 100
    }

    /// The last message a new summary should cover, or nil when there is nothing worth it. The
    /// kept tail starts at a user message (so the request goes summary, then a user turn, as every
    /// chat template accepts), holds at least the newest user turn and everything after it, and
    /// grows backwards by whole turns while it fits `keptShare` of `limitTokens`. A boundary never
    /// goes back past an existing one: a new summary always covers more.
    /// `before` leaves out messages from the end (the reply about to be written).
    public static func boundary(in messages: [Message], current: Int?, limitTokens: Int?, before end: Int? = nil) -> Int? {
        let end = min(end ?? messages.count, messages.count)
        let userStarts = (0..<end).filter { messages[$0].role == .user }
        guard let lastUser = userStarts.last else { return nil }
        let budget = Int(Double(limitTokens ?? 0) * keptShare)
        var tailStart = lastUser
        var tailTokens = (lastUser..<end).reduce(0) { $0 + ContextBudget.estimateTokens(message: messages[$1]) }
        for start in userStarts.dropLast().reversed() {
            let turn = (start..<tailStart).reduce(0) { $0 + ContextBudget.estimateTokens(message: messages[$1]) }
            guard budget > 0, tailTokens + turn <= budget else { break }
            tailStart = start
            tailTokens += turn
        }
        let through = tailStart - 1
        guard through >= 0, through > (current ?? -1) else { return nil }
        // Only blank failed replies would be summarized: not worth a request.
        guard messages[((current ?? -1) + 1)...through].contains(where: { !isSkipped($0) }) else { return nil }
        return through
    }

    /// Messages a request leaves out anyway: blank failed replies.
    static func isSkipped(_ message: Message) -> Bool {
        message.role == .assistant && (message.toolRounds ?? []).isEmpty && Message.isBlank(message.content)
    }

    // MARK: The summary request

    /// The instruction the summary request ends with. Model-facing, so English.
    public static let instruction = """
        Summarize the conversation above so that it can continue without it. Write in the language \
        the conversation is in. Keep: what the user wants and has decided, facts, names, numbers, \
        file names and addresses that came up, what tools returned that still matters, code that is \
        still being worked on (quote it if it is short), questions still open, and where things were \
        left. Leave out pleasantries and anything already settled and no longer needed. Write the \
        summary only, with no introduction, as compact notes.
        """

    /// The messages of one summary request: the previous summary (if any) as a first user turn, the
    /// messages to fold in with images replaced by a note and tool rounds left to the request's
    /// flattening, then the instruction. A summary request carries no tools, so earlier rounds go as
    /// text. Roles strictly alternate from a user turn, as some chat templates require: a piece that
    /// starts with a reply, or two turns of one role left next to each other by a skipped failed
    /// reply, are joined rather than sent as they are.
    public static func requestMessages(previousSummary: String?, messages: [Message]) -> [Message] {
        var out: [Message] = []
        if let previousSummary, !Message.isBlank(previousSummary) {
            out.append(Message(role: .user, content: "Summary of the conversation so far:\n\n" + previousSummary))
        }
        for message in messages where !isSkipped(message) {
            var copy = message
            // Images would cost a request that may already be near its size limit.
            let images = copy.attachments.filter { $0.kind == .image }.count
            copy.attachments.removeAll { $0.kind == .image }
            if images > 0 { copy.content += "\n\n[\(images == 1 ? "An image" : "\(images) images") was attached here.]" }
            copy.reasoning = nil
            // A reply cannot open the request: it follows the summary turn, or a note that the
            // conversation started earlier.
            if out.isEmpty, copy.role != .user {
                out.append(Message(role: .user, content: "(The conversation began earlier.)"))
            }
            out.append(copy)
        }
        // The instruction is the last user turn; after an earlier user turn, a short reply keeps
        // the roles alternating.
        if out.last?.role == .user { out.append(Message(role: .assistant, content: "(No reply yet.)")) }
        out.append(Message(role: .user, content: instruction))
        return alternating(out)
    }

    /// Joins neighbours of the same role (text, and a user turn's attachments) so roles alternate.
    static func alternating(_ messages: [Message]) -> [Message] {
        var out: [Message] = []
        for message in messages {
            if let last = out.last, last.role == message.role {
                var joined = last
                joined.content = [last.content, message.content].filter { !Message.isBlank($0) }.joined(separator: "\n\n")
                joined.attachments += message.attachments
                joined.toolRounds = (last.toolRounds ?? []) + (message.toolRounds ?? [])
                if joined.toolRounds?.isEmpty == true { joined.toolRounds = nil }
                out[out.count - 1] = joined
            } else {
                out.append(message)
            }
        }
        return out
    }

    /// The covered messages in pieces that each fit `budgetTokens`, so a history too long for one
    /// request is folded into the summary a piece at a time. A message longer than the budget goes
    /// alone; the request's own size guard decides what happens to it.
    public static func chunks(_ messages: [Message], budgetTokens: Int) -> [[Message]] {
        var out: [[Message]] = []
        var current: [Message] = []
        var used = 0
        for message in messages where !isSkipped(message) {
            let cost = ContextBudget.estimateTokens(message: message)
            if !current.isEmpty, used + cost > budgetTokens {
                out.append(current)
                current = []
                used = 0
            }
            current.append(message)
            used += cost
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

extension Conversation {
    /// Where the compaction's summary ends, if it still matches this history.
    public var compactionBoundary: Int? {
        guard let compaction else { return nil }
        return messages.firstIndex { $0.id == compaction.throughMessageID }
    }

    /// What the next request carries. See `Compaction`.
    public var effectiveHistory: EffectiveHistory {
        guard let compaction, let boundary = compactionBoundary else {
            return EffectiveHistory(messages: messages, summaryBlock: nil, anchorsFrom: 0, coveredCount: 0)
        }
        let tail = Array(messages[(boundary + 1)...])
        // A count from before the summary existed was taken with the whole history in the prompt.
        // (truncate and forked move the mark back when its message goes: Conversation.restaleCompaction.)
        var anchorsFrom = 0
        if let stale = compaction.countsStaleThroughID, let index = tail.firstIndex(where: { $0.id == stale }) {
            anchorsFrom = index + 1
        }
        return EffectiveHistory(messages: tail, summaryBlock: Compaction.block(compaction.summary),
                                anchorsFrom: anchorsFrom, coveredCount: boundary + 1)
    }
}
