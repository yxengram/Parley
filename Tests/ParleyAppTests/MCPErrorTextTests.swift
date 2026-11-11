import Foundation
import Testing
@testable import Parley
import ParleyCore

// MCPError's text stays English in ParleyCore; MCPErrorText shows the known sentences in the
// interface language. Under `swift test` that language is English, so every known sentence must
// come back exactly as ParleyCore wrote it (a wrong key or a broken pattern would change it).

@Test func mcpErrorTextIsUnchangedInEnglish() {
    let errors: [MCPError] = [
        .commandNotFound(name: "npx", searched: ["/usr/bin", "/bin"]),
        .commandNotFound(name: "/opt/tools/server", searched: []),
        .commandNotFound(name: "npx -y @example/server", searched: []),
        .notExecutable("/tmp/server"),
        .spawnFailed("permission denied"),
        .exited(status: 0, stderrTail: []),
        .exited(status: 3, stderrTail: ["Error: boom", "at main"]),
        .startupTimedOut(seconds: 30, stderrTail: ["waiting"]),
        .unsupportedVersion("2023-01-01"),
        .rpc(code: -32601, message: "Method not found", data: nil),
        .rpc(code: 0, message: "Oops", data: nil),
        .needsAuthorization(status: 401),
        .needsAuthorization(status: 403),
        .credentialsRefused(status: 401),
        .insufficientScope,
        .messageTooLarge,
        .streamEnded,
        .sessionExpired,
        .timedOut(seconds: 60),
        .invalidHeader("X-Bad"),
        .invalidURL,
        .disabled,
        .notConfigured,
        .inputNotSupported,
        .stopped,
        .tooManyCrashes(limit: 3),
    ]
    for error in errors {
        for text in [error.errorDescription ?? "", error.summary] {
            #expect(MCPErrorText.shown(text) == text, "\(text)")
        }
    }
    // Unknown text, a server's own message and the system sentences pass through.
    for text in ["Something else.", "Could not connect to the server.", "", "x\ny"] {
        #expect(MCPErrorText.shown(text) == text)
    }
    #expect(MessageRow.shownServerFailure("filesystem: This server was stopped.") == "filesystem: This server was stopped.")
}

@Test func storedSystemSentencesAreShownUnchangedInEnglish() {
    for sentence in SystemErrorText.urlErrors.values {
        #expect(ErrorPresentation.shownSystemText("Is it on? " + sentence) == "Is it on? " + sentence)
        #expect(ErrorPresentation.systemSentences.contains { $0.english == sentence }, "\(sentence)")
    }
    // Stored English is still recognized and presented as before.
    let p = ErrorPresentation.make("Could not connect to the server.", providerName: "LM Studio", baseURL: "http://localhost:1234/v1")
    #expect(p.title == "Can't reach LM Studio at localhost")
    #expect(p.detail == "Is the server running? Could not connect to the server.")
}
