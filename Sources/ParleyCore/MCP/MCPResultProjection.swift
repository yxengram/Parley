import Foundation

// What the model gets from a tools/call result. A tool message is plain text on these servers, so
// everything is reduced to text, with a plain note for what could not be carried.

public enum ToolResultProjection {
    /// Pure. `maxCharacters` counts Characters, not bytes.
    public static func project(result: JSONValue, maxCharacters: Int) -> ToolCallResult {
        var pieces: [String] = []
        var omitted: [String] = []

        for item in result["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text":
                if let text = item["text"]?.stringValue { pieces.append(text) }
            case "image", "audio":
                omitted.append(describe(mimeType: item["mimeType"]?.stringValue ?? item["type"]?.stringValue ?? "data",
                                        base64: item["data"]?.stringValue))
            case "resource":
                let resource = item["resource"]
                if let text = resource?["text"]?.stringValue {
                    pieces.append(text)
                } else {
                    omitted.append(describe(mimeType: resource?["mimeType"]?.stringValue ?? "resource",
                                            base64: resource?["blob"]?.stringValue))
                }
            case "resource_link":
                // Never fetched.
                let name = item["name"]?.stringValue ?? ""
                let uri = item["uri"]?.stringValue ?? ""
                pieces.append("[Link: \(name) \(uri)]")
            case let other:
                let type = other ?? "unknown"
                pieces.append("[Unsupported content: \(type)]")
                omitted.append(type)
            }
        }

        var text = pieces.joined(separator: "\n")
        if pieces.isEmpty, let structured = result["structuredContent"], !structured.isNull {
            text = structured.sortedJSONText
        }
        if !omitted.isEmpty {
            if !text.isEmpty { text += "\n\n" }
            text += "[Parley could not pass on: \(omitted.joined(separator: "; ")). Tool messages cannot carry images or audio on these servers.]"
        }

        let isError = result["isError"]?.boolValue == true
        if isError { text = "The tool reported an error:\n" + text }

        var original: Int?
        let count = text.count
        if count > maxCharacters {
            original = count
            let kept = max(0, maxCharacters)
            text = String(text.prefix(kept)) + "\n\n[Truncated by Parley: showing the first \(kept) of \(count) characters.]"
        }
        if text.isEmpty { text = ToolResultText.empty }

        return ToolCallResult(status: isError ? .toolError : .completed, text: text, originalCharacters: original,
                              omitted: omitted.isEmpty ? nil : omitted)
    }

    /// "image/png, 230 KB", from the base64 length: the data itself is never decoded or kept.
    private static func describe(mimeType: String, base64: String?) -> String {
        guard let base64, !base64.isEmpty else { return mimeType }
        let bytes = base64.utf8.count / 4 * 3
        if bytes < 1024 { return "\(mimeType), \(bytes) bytes" }
        if bytes < 1024 * 1024 { return "\(mimeType), \(bytes / 1024) KB" }
        return String(format: "%@, %.1f MB", mimeType, Double(bytes) / 1_048_576)
    }
}
