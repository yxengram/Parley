import CryptoKit
import Foundation

// Everything about a tool's definition that needs no server: the names the model sees, the schema
// it receives, the fingerprint that pins "Always Allow", and x-mcp-header parameters.

public enum MCPToolFingerprint {
    public static func make(name: String, description: String?, inputSchema: JSONValue) -> String {
        let headers = MCPHeaderMirror.annotations(in: inputSchema).list.map { annotation in
            JSONValue.string(annotation.path.joined(separator: "/") + "=" + annotation.header)
        }
        let body: JSONValue = .object([
            "name": .string(name),
            "description": description.map(JSONValue.string) ?? .null,
            "inputSchema": inputSchema,
            "headers": .array(headers),
        ])
        return String(sha256Hex(body.sortedJSONData).prefix(16))
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `<server>__<tool>`, lower snake case, 64 characters at most, deterministic. Lower snake case on
/// purpose: LM Studio normalizes names to forms like it, and these survive unchanged. The prefix is
/// always there, so enabling a second server renames nothing.
public enum MCPToolNamer {
    public static func assign(_ servers: [(config: MCPServerConfig, tools: [MCPTool])]) -> [MCPToolBinding] {
        let ordered = servers.sorted {
            (slug($0.config.name), $0.config.id.uuidString) < (slug($1.config.name), $1.config.id.uuidString)
        }
        var prefixes: Set<String> = []
        var taken: Set<String> = []
        var out: [MCPToolBinding] = []
        for server in ordered {
            var prefix = trimmed(String(slug(server.config.name).prefix(20)))
            if prefix.isEmpty { prefix = "mcp" }
            if prefixes.contains(prefix) {
                prefix = trimmed(String(prefix.prefix(15))) + "_" + server.config.id.uuidString.prefix(4).lowercased()
            }
            prefixes.insert(prefix)
            for tool in server.tools.sorted(by: { $0.name < $1.name }) {
                let name = uniqueName(prefix: prefix, toolName: tool.name, taken: &taken)
                out.append(MCPToolBinding(exposedName: name, serverID: server.config.id, serverName: server.config.name, tool: tool))
            }
        }
        return out.sorted { $0.exposedName < $1.exposedName }
    }

    private static func uniqueName(prefix: String, toolName: String, taken: inout Set<String>) -> String {
        var tool = slug(toolName)
        if tool.isEmpty { tool = "tool" }
        let room = 64 - prefix.count - 2
        let suffix = "_" + sha256Hex(Data(toolName.utf8)).prefix(6)
        func suffixed(_ extra: String = "") -> String {
            let tail = suffix + extra
            return prefix + "__" + trimmed(String(tool.prefix(room - tail.count))) + tail
        }
        var name = tool.count > room ? suffixed() : prefix + "__" + tool
        if taken.contains(name) { name = suffixed() }
        var counter = 2
        while taken.contains(name) {
            // Only a hash collision gets here.
            name = suffixed("_\(counter)")
            counter += 1
        }
        taken.insert(name)
        return name
    }

    /// camelCase split with "_", lower case, everything outside [a-z0-9] collapsed to one "_".
    static func slug(_ text: String) -> String {
        var out = ""
        var previousIsLowerOrDigit = false
        var pendingSeparator = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isUpper = value >= 0x41 && value <= 0x5A
            let isLower = value >= 0x61 && value <= 0x7A
            let isDigit = value >= 0x30 && value <= 0x39
            guard isUpper || isLower || isDigit else {
                pendingSeparator = !out.isEmpty
                previousIsLowerOrDigit = false
                continue
            }
            if pendingSeparator || (isUpper && previousIsLowerOrDigit) { out.append("_") }
            pendingSeparator = false
            out.unicodeScalars.append(isUpper ? Unicode.Scalar(value + 32)! : scalar)
            previousIsLowerOrDigit = isLower || isDigit
        }
        return out
    }

    private static func trimmed(_ text: String) -> String {
        var out = Substring(text)
        while out.last == "_" { out = out.dropLast() }
        return String(out)
    }
}

/// Only what the servers require of a tool's parameters: llama.cpp rejects boolean subschemas, and
/// an absent schema must still be an object. Everything else passes through, `$ref` included
/// (never dereferenced).
public enum MCPSchema {
    private static let maxDepth = 64
    private static let empty: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    public static func normalized(_ schema: JSONValue?) -> JSONValue {
        guard case .object(var root)? = schema, !root.isEmpty else { return empty }
        switch root["type"] {
        case nil, .array?: root["type"] = .string("object")
        default: break
        }
        return clean(.object(root), depth: 0)
    }

    private static func clean(_ value: JSONValue, depth: Int) -> JSONValue {
        guard depth < maxDepth, case .object(var object) = value else { return value }
        for key in ["properties", "$defs", "definitions"] {
            guard case .object(let map)? = object[key] else { continue }
            var out: [String: JSONValue] = [:]
            for (name, sub) in map {
                switch sub {
                case .bool(false): continue
                default: out[name] = subschema(sub, depth: depth)
                }
            }
            object[key] = .object(out)
        }
        if let items = object["items"] {
            if case .array(let list) = items {
                object["items"] = .array(list.map { subschema($0, depth: depth) })
            } else {
                object["items"] = subschema(items, depth: depth)
            }
        }
        for key in ["anyOf", "oneOf", "allOf"] {
            guard case .array(let list)? = object[key] else { continue }
            object[key] = .array(list.filter { $0 != .bool(false) }.map { subschema($0, depth: depth) })
        }
        return .object(object)
    }

    private static func subschema(_ value: JSONValue, depth: Int) -> JSONValue {
        if case .bool = value { return .object([:]) }
        return clean(value, depth: depth + 1)
    }
}

/// `x-mcp-header`: the spec makes clients mirror marked parameters into `Mcp-Param-{name}` headers
/// on Streamable HTTP, and leave out tools that mark them wrongly.
enum MCPHeaderMirror {
    struct Annotation: Equatable {
        var path: [String]
        var header: String
        var type: String
    }

    /// Keywords whose values are data, not schemas.
    private static let dataKeywords: Set<String> = ["default", "const", "enum", "examples", "example"]
    private static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Every annotation by path, and why the definition is invalid, if it is.
    static func annotations(in schema: JSONValue) -> (list: [Annotation], problem: String?) {
        var list: [Annotation] = []
        var problem: String?
        func walk(_ value: JSONValue, path: [String], reachable: Bool, depth: Int) {
            guard depth < 128 else { return }
            switch value {
            case .array(let items):
                for item in items { walk(item, path: path, reachable: false, depth: depth + 1) }
            case .object(let object):
                if let mark = object["x-mcp-header"] {
                    if !reachable || path.isEmpty {
                        problem = problem ?? "x-mcp-header is only allowed on a parameter reached through `properties` alone"
                    } else if let header = mark.stringValue, !header.isEmpty,
                              header.unicodeScalars.allSatisfy(tokenCharacters.contains) {
                        let type = object["type"]?.stringValue ?? ""
                        if ["string", "integer", "boolean"].contains(type) {
                            list.append(Annotation(path: path, header: header, type: type))
                        } else {
                            problem = problem ?? "x-mcp-header is only allowed on string, integer and boolean parameters"
                        }
                    } else {
                        problem = problem ?? "x-mcp-header is not a valid header name"
                    }
                }
                for key in object.keys.sorted() where !dataKeywords.contains(key) && key != "x-mcp-header" {
                    guard let child = object[key] else { continue }
                    if key == "properties", case .object(let properties) = child {
                        for name in properties.keys.sorted() {
                            walk(properties[name]!, path: path + [name], reachable: reachable, depth: depth + 1)
                        }
                    } else {
                        walk(child, path: path, reachable: false, depth: depth + 1)
                    }
                }
            default:
                break
            }
        }
        walk(schema, path: [], reachable: true, depth: 0)
        var seen: Set<String> = []
        for annotation in list where !seen.insert(annotation.header.lowercased()).inserted {
            problem = problem ?? "x-mcp-header \(annotation.header) is used twice"
        }
        return (list, problem)
    }

    /// `Mcp-Param-*` for one call. A value that is absent or null has no header.
    static func headers(schema: JSONValue, arguments: [String: JSONValue]) -> [String: String] {
        var out: [String: String] = [:]
        for annotation in annotations(in: schema).list {
            var value: JSONValue? = .object(arguments)
            for key in annotation.path { value = value?[key] }
            let text: String?
            switch value {
            case .string(let s)?: text = s
            case .bool(let b)?: text = b ? "true" : "false"
            case .int(let i)?: text = String(i)
            case .double?: text = value?.intValue.map(String.init)
            default: text = nil
            }
            if let text { out["Mcp-Param-" + annotation.header] = encoded(text) }
        }
        return out
    }

    /// The value as it is, or `=?base64?…?=` when it is not plain ASCII, has leading or trailing
    /// space, or looks like that form itself.
    static func encoded(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
        let padded = value.hasPrefix(" ") || value.hasSuffix(" ")
        let sentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        guard !plain || padded || sentinel else { return value }
        return "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }
}
