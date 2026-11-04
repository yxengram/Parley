import Foundation
import Testing
@testable import ParleyCore

// "None (no thinking)" for every server: the body shape per server kind, the bodies that must not
// change, what counts as a refusal, and the persisted reply notes.

private let history = [Message(role: .user, content: "hi")]

private func sortedJSON(_ body: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
}

/// Request bodies written by the version before "None" was offered everywhere (dumped from that
/// code with sorted keys): server kind | effort | include_usage | thinking budget | body, then the
/// Strata "None" bodies. Everything except "None" on a non-Strata server must stay byte-identical.
private let goldenBodies = #"""
nil|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
nil|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
nil|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
nil|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
nil|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
nil|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
nil|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
nil|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
nil|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
nil|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
lmStudio|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
lmStudio|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
lmStudio|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
lmStudio|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
lmStudio|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
lmStudio|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
lmStudio|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
lmStudio|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
lmStudio|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
llamaCpp|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
llamaCpp|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
llamaCpp|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
llamaCpp|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
llamaCpp|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
llamaCpp|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
llamaCpp|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
llamaCpp|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
llamaCpp|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
vLLM|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
vLLM|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
vLLM|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
vLLM|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
vLLM|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
vLLM|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
vLLM|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
vLLM|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
vLLM|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
ollama|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
ollama|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
ollama|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
ollama|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
ollama|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
ollama|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
ollama|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
ollama|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
ollama|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","return_progress":true,"stream":true,"temperature":0.5}
strata|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"return_progress":true,"stream":true,"temperature":0.5}
strata|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","return_progress":true,"stream":true,"temperature":0.5}
strata|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"reasoning_effort":"low","return_progress":true,"stream":true,"temperature":0.5}
strata|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"reasoning_effort":"low","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","return_progress":true,"stream":true,"temperature":0.5}
strata|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"reasoning_effort":"medium","return_progress":true,"stream":true,"temperature":0.5}
strata|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"reasoning_effort":"medium","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","return_progress":true,"stream":true,"temperature":0.5}
strata|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"reasoning_effort":"high","return_progress":true,"stream":true,"temperature":0.5}
strata|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strata|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_budget_tokens":512,"reasoning_effort":"high","return_progress":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|nil|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
hosted|nil|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"temperature":0.5}
hosted|nil|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|nil|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|low|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
hosted|low|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"temperature":0.5}
hosted|low|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|low|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|medium|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
hosted|medium|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"temperature":0.5}
hosted|medium|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|medium|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"medium","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|high|false|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
hosted|high|false|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"temperature":0.5}
hosted|high|true|nil|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
hosted|high|true|512|{"max_tokens":100,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"high","stream":true,"stream_options":{"include_usage":true},"temperature":0.5}
strataNone|false|nil|{"messages":[{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"none","return_progress":true,"stream":true}
strataNone|true|nil|{"messages":[{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"none","return_progress":true,"stream":true,"stream_options":{"include_usage":true}}
strataNone|false|512|{"messages":[{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"none","return_progress":true,"stream":true}
strataNone|true|512|{"messages":[{"content":"hi","role":"user"}],"model":"m","reasoning_effort":"none","return_progress":true,"stream":true,"stream_options":{"include_usage":true}}
"""#

@Suite struct ThinkingOffRequestTests {
    private func kind(_ name: String) -> InferenceServerKind? {
        name == "nil" ? nil : InferenceServerKind(rawValue: name)
    }

    // Not sent and low/medium/high are what they were for every server kind, with and without
    // stream_options and a thinking budget; Strata's "None" is unchanged too.
    @Test func otherChoicesAreByteIdenticalToBefore() throws {
        let lines = goldenBodies.split(separator: "\n").map(String.init)
        #expect(lines.count == 116)
        for line in lines {
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            var options: ChatRequestOptions
            let usage: Bool
            if fields[0] == "strataNone" {
                let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                options = ChatRequestOptions(model: "m")
                options.serverKind = .strata
                options.disablesThinking = true
                options.reasoningBudgetTokens = Int(parts[2])
                usage = parts[1] == "true"
                #expect(try sortedJSON(ChatClient.buildRequestBody(messages: history, options: options, includeUsage: usage)) == parts[3], "\(line)")
                continue
            }
            options = ChatRequestOptions(model: "m", systemPrompt: "s", temperature: 0.5, maxTokens: 100,
                                         reasoningEffort: fields[1] == "nil" ? nil : ReasoningEffort(rawValue: fields[1]))
            options.serverKind = kind(fields[0])
            options.reasoningBudgetTokens = Int(fields[3])
            usage = fields[2] == "true"
            #expect(try sortedJSON(ChatClient.buildRequestBody(messages: history, options: options, includeUsage: usage)) == fields[4], "\(line)")
        }
    }

    private func noneBody(_ kind: InferenceServerKind?, effort: ReasoningEffort? = nil, budget: Int? = nil, omitted: Bool = false) throws -> String {
        var o = ChatRequestOptions(model: "m", reasoningEffort: effort)
        o.serverKind = kind
        o.disablesThinking = true
        o.reasoningBudgetTokens = budget
        o.omitsThinkingOff = omitted
        return try sortedJSON(ChatClient.buildRequestBody(messages: history, options: o))
    }

    // The confirmed shape per server, and reasoning_effort "none" alone where nothing is confirmed.
    @Test func noneBodyPerServerKind() throws {
        let messages = #""messages":[{"content":"hi","role":"user"}],"model":"m""#
        let effortNone = #"{\#(messages),"reasoning_effort":"none","stream":true}"#
        let templateOff = #"{"chat_template_kwargs":{"enable_thinking":false},\#(messages),"stream":true}"#
        #expect(try noneBody(.strata) == #"{\#(messages),"reasoning_effort":"none","return_progress":true,"stream":true}"#)
        #expect(try noneBody(.llamaCpp) == templateOff)
        #expect(try noneBody(.vLLM) == templateOff)
        #expect(try noneBody(.ollama) == effortNone)
        #expect(try noneBody(.lmStudio) == effortNone)
        #expect(try noneBody(.hosted) == effortNone)
        #expect(try noneBody(nil) == effortNone)
        // A JSON boolean, never 0 or "false" (llama.cpp answers a string with a 400).
        #expect(try noneBody(.vLLM).contains(#""enable_thinking":false"#))
        // "None" replaces an effort; on Strata the budget still never goes with it.
        #expect(try noneBody(.vLLM, effort: .high) == templateOff)
        #expect(try noneBody(.lmStudio, effort: .low) == effortNone)
        #expect(!(try noneBody(.strata, budget: 512)).contains("reasoning_budget_tokens"))
    }

    // After a refusal the fields are left out: the body is the "Not sent" one (Strata keeps its
    // progress flag and still sends no budget, since the user asked for no thinking).
    @Test func omittedNoneIsTheNotSentBody() throws {
        let kinds: [InferenceServerKind?] = [nil, .lmStudio, .llamaCpp, .vLLM, .ollama, .hosted]
        for kind in kinds {
            var plain = ChatRequestOptions(model: "m")
            plain.serverKind = kind
            #expect(try noneBody(kind, omitted: true) == sortedJSON(ChatClient.buildRequestBody(messages: history, options: plain)))
        }
        #expect(try noneBody(.strata, budget: 512, omitted: true) == #"{"messages":[{"content":"hi","role":"user"}],"model":"m","return_progress":true,"stream":true}"#)
        var o = ChatRequestOptions(model: "m")
        o.disablesThinking = true
        #expect(ChatClient.sentThinkingOffFields(o) == ["reasoning_effort"])
        o.omitsThinkingOff = true
        #expect(ChatClient.sentThinkingOffFields(o).isEmpty)
        o.disablesThinking = false
        o.omitsThinkingOff = false
        #expect(ChatClient.sentThinkingOffFields(o).isEmpty)
    }

    // Only a 400/422 that names a field that was sent; never an overflow or any other error.
    @Test func whatCountsAsARefusal() {
        let effort = ["reasoning_effort"]
        let kwargs = ["chat_template_kwargs"]
        let openAI = #"{"error":{"message":"Unsupported value: 'none' is not supported with the 'gpt-5' model. Supported values are: 'minimal', 'low', 'medium', and 'high'.","type":"invalid_request_error","param":"reasoning_effort","code":"unsupported_value"}}"#
        #expect(ThinkingOffSupport.isRejection(status: 400, body: openAI, sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: "Unknown parameter: 'reasoning_effort'.", sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: #"{"error":{"param":"reasoning.effort"}}"#, sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 422, body: #"{"detail":[{"loc":["body","chat_template_kwargs"],"msg":"extra"}]}"#, sentFields: kwargs))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: #"invalid type for "enable_thinking" (expected boolean, got string)"#, sentFields: kwargs))
        // Not sent, another field, another status, an overflow, a generic 400.
        #expect(!ThinkingOffSupport.isRejection(status: 400, body: openAI, sentFields: []))
        #expect(!ThinkingOffSupport.isRejection(status: 400, body: openAI, sentFields: kwargs))
        #expect(!ThinkingOffSupport.isRejection(status: 500, body: openAI, sentFields: effort))
        #expect(!ThinkingOffSupport.isRejection(status: 401, body: openAI, sentFields: effort))
        #expect(!ThinkingOffSupport.isRejection(
            status: 400, body: "This model's maximum context length is 8192 tokens. However, you requested 9000 tokens (reasoning_effort none).",
            sentFields: effort))
        #expect(!ThinkingOffSupport.isRejection(status: 400, body: #"{"error":{"message":"mock bad request"}}"#, sentFields: effort))
        // Refusals that do not name the field but say what it controls (streamChat only counts
        // them once the retry without the field is accepted): Ollama, Gemini, spaced wording.
        #expect(ThinkingOffSupport.isRejection(status: 400, body: #"{"error":"invalid reasoning value: \"none\" (must be \"high\", \"medium\", \"low\")"}"#, sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: "Thinking can't be disabled for this model", sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: "Invalid reasoning effort 'none'", sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: "this template does not support thinking", sentFields: kwargs))
        // Never on Strata (verified to accept "none"), whatever the text says.
        #expect(!ThinkingOffSupport.isRejection(status: 400, body: openAI, sentFields: effort, serverKind: .strata))
        #expect(!ThinkingOffSupport.isRejection(status: 400, body: "This model is not ready.", sentFields: effort))
        #expect(ThinkingOffSupport.isRejection(status: 400, body: openAI, sentFields: effort, serverKind: .lmStudio))
    }
}

@Suite struct ThinkingOffStorageTests {
    // Files written before the reply notes existed decode; new ones keep them, plain and encrypted;
    // an older Parley ignores the keys it does not know (synthesized Decodable).
    @Test func replyNotesAreBackwardCompatible() throws {
        let old = try JSONDecoder().decode(Message.self, from: Data(#"""
        {"id":"7F0C1B8E-2D5A-4C3B-9E1F-0A1B2C3D4E5F","role":"assistant","content":"x","attachments":[],
         "createdAt":0,"isComplete":true}
        """#.utf8))
        #expect(old.thinkingOffNotAccepted == nil && old.thinkingOffIgnored == nil)

        var refused = Message(role: .assistant, content: "a", reasoning: "thought")
        refused.thinkingOffNotAccepted = true
        var ignored = Message(role: .assistant, content: "b", reasoning: "thought")
        ignored.thinkingOffIgnored = true
        var settings = ConversationSettings(model: "m")
        settings.disablesThinking = true
        let conversation = Conversation(settings: settings, messages: [refused, ignored])

        let plain = try ConversationFile.decodePlain(ConversationFile.encode(conversation, encryption: nil))
        #expect(plain.messages[0].thinkingOffNotAccepted == true && plain.messages[0].thinkingOffIgnored == nil)
        #expect(plain.messages[1].thinkingOffIgnored == true && plain.messages[1].thinkingOffNotAccepted == nil)
        #expect(plain.settings.disablesThinking == true && plain.settings.reasoningEffort == nil)

        let key = try ConversationCrypto.newKey(password: "pw", iterations: 1000)
        let data = try ConversationFile.encode(conversation, encryption: key)
        let decrypted = try ConversationFile.decodeEncrypted(data, key: key)
        #expect(decrypted.messages.map(\.thinkingOffNotAccepted) == [true, nil])
        #expect(decrypted.messages.map(\.thinkingOffIgnored) == [nil, true])

        // What an older version sees: the same Message without the new keys.
        struct OldMessage: Decodable { var id: UUID; var content: String; var reasoning: String? }
        let encoded = try JSONEncoder().encode(refused)
        #expect(String(decoding: encoded, as: UTF8.self).contains("thinkingOffNotAccepted"))
        #expect(try JSONDecoder().decode(OldMessage.self, from: encoded).content == "a")
    }
}
