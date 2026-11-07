import Foundation

// The tools Parley itself offers: what they are called, what the model is told about them, and which
// of them run without asking. They reach the reply loop as one synthetic server, so everything the
// loop does for a server (retries, notes, rounds, Stop, Lock, ReAct, switched off mid-reply) applies
// with no change there. With every tool off that server is not in the list at all, and a request is
// what it was before these tools existed.

public enum BuiltInTools {
    /// Never in `AppSettings.mcpServers`, so nothing can edit, delete or start it.
    public static let serverID = UUID(uuidString: "B17B0057-7001-4A11-8F00-000000000001")!
    public static let serverName = "Parley"
    /// `builtin__<tool>`. A real server may hold the same prefix: see `bindings(for:avoiding:)`.
    public static let namePrefix = "builtin"
    /// For a whole call: a chain of redirects, or a slow disk.
    static let callTimeout: Double = 60

    public enum Tool: String, CaseIterable, Sendable {
        case currentTime = "current_time"
        case calculate
        case listFiles = "list_files"
        case readFile = "read_file"
        case fetchURL = "fetch_url"

        /// The Settings toggle.
        public var title: String {
            switch self {
            case .currentTime: return "Current Time"
            case .calculate: return "Calculator"
            case .listFiles: return "List Files"
            case .readFile: return "Read File"
            case .fetchURL: return "Fetch Web Page"
            }
        }

        /// Does nothing until a folder is chosen in Settings.
        public var needsFolder: Bool { self == .listFiles || self == .readFile }

        /// Reads the user's files or contacts a website, so there is no Always Allow: a page or file
        /// can tell the model to send what it read somewhere, and each card is where that stops.
        public var asksEveryTime: Bool { needsFolder || self == .fetchURL }

        fileprivate var description: String {
            switch self {
            case .currentTime:
                return "Returns the current local date, time, weekday, UTC offset and time zone of the user's computer."
            case .calculate:
                return "Evaluates an arithmetic expression exactly as written. Operators: + - * / % ^ and parentheses. "
                    + "Functions: sqrt abs sin cos tan asin acos atan log ln exp floor ceil round. Constants: pi e. "
                    + "Angles are in radians; log is base 10, ln is natural."
            case .listFiles:
                return "Lists one folder inside the folder the user shared, not recursively. Paths are relative to that "
                    + "folder, whose own path is \".\". Hidden files are never shown. The user approves every call."
            case .readFile:
                return "Reads a UTF-8 text file inside the folder the user shared. Paths are relative to that folder. "
                    + "A long file comes back in parts: the result says how to ask for the next one. Hidden files "
                    + "cannot be read. The user approves every call."
            case .fetchURL:
                return "Fetches one public web page over http or https and returns its text. Scripts are not run and "
                    + "images are not loaded. Private and local addresses are refused. A redirect to another address "
                    + "is reported, not followed. The user approves every call."
            }
        }

        fileprivate var parameters: JSONValue {
            func string(_ description: String) -> JSONValue {
                .object(["type": .string("string"), "description": .string(description)])
            }
            var properties: [String: JSONValue] = [:]
            var required: [String] = []
            switch self {
            case .currentTime:
                break
            case .calculate:
                properties["expression"] = string("The expression, for example (2 + 3) * sqrt(16).")
                required = ["expression"]
            case .listFiles:
                properties["path"] = string("The folder, relative to the shared folder. Leave it out for the shared folder itself.")
            case .readFile:
                properties["path"] = string("The file, relative to the shared folder.")
                properties["start_line"] = .object([
                    "type": .string("integer"),
                    "description": .string("The first line to return, counted from 1. Leave it out to start at the top."),
                ])
                required = ["path"]
            case .fetchURL:
                properties["url"] = string("The full http or https address.")
                required = ["url"]
            }
            var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
            if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
            return .object(schema)
        }

        var definition: MCPTool {
            MCPTool(name: rawValue, description: description, inputSchema: MCPSchema.normalized(parameters))
        }
    }

    /// Every definition, in `Tool.allCases` order. Independent of settings: nothing in them comes from
    /// the user, the shared folder's path and name least of all.
    public static var definitions: [MCPTool] { Tool.allCases.map(\.definition) }

    /// The synthetic server, or nil when no tool is on. A tool that is off is in `disabledTools`, so
    /// a reply that was already running sees it go the way it sees any other tool switched off.
    public static func serverConfig(_ settings: BuiltInToolSettings) -> MCPServerConfig? {
        let on = settings.effectiveTools
        guard !on.isEmpty else { return nil }
        return MCPServerConfig(id: serverID, name: serverName, kind: MCPServerConfig.kindBuiltIn, isEnabled: true,
                               disabledTools: Tool.allCases.filter { !on.contains($0) }.map(\.rawValue),
                               callTimeout: callTimeout)
    }

    /// What `config` offers, under the fixed prefix. A real server's names must not depend on these
    /// switches, so on a clash with `taken` the built-in moves, to a form no server can get: a slug
    /// never starts with "_". "parley" keeps it apart in `binding(forFunctionName:)`, which ignores "_".
    public static func bindings(for config: MCPServerConfig, avoiding taken: Set<String> = []) -> [MCPToolBinding] {
        definitions.filter { !config.disabledTools.contains($0.name) }.map {
            let plain = namePrefix + "__" + $0.name
            let name = taken.contains(plain) ? namePrefix + "___parley_" + $0.name : plain
            return MCPToolBinding(exposedName: name, serverID: serverID, serverName: serverName, tool: $0)
        }
    }

    /// True only for a call of a tool that may never be remembered as allowed.
    public static func asksEveryTime(_ binding: MCPToolBinding) -> Bool {
        guard binding.serverID == serverID else { return false }
        return Tool(rawValue: binding.tool.name)?.asksEveryTime ?? true
    }

    /// True for a call that works in the shared folder, whose Allow means the folder its card named.
    public static func readsFolder(_ binding: MCPToolBinding) -> Bool {
        binding.serverID == serverID && Tool(rawValue: binding.tool.name)?.needsFolder == true
    }

    /// The line under the tool's name on the approval card. The card is local, so the folder's name
    /// may be here; it never goes to the model. The path is here too: the arguments block scrolls and
    /// the model picks its keys, so a decoy could fill what shows there and push the real one out of view.
    public static func approvalDetail(toolName: String, arguments: [String: JSONValue], folderPath: String?) -> String {
        let plain = "Built-in tool"
        switch Tool(rawValue: toolName) {
        case .fetchURL?:
            guard let text = arguments["url"]?.stringValue, let host = BuiltInFetcher.parse(text)?.host else { return plain }
            return "\(plain), contacts \(host)"
        case let tool? where tool.needsFolder:
            guard let folderPath, !folderPath.isEmpty else { return plain }
            let folder = "\(plain), in folder \(URL(fileURLWithPath: folderPath).lastPathComponent)"
            guard let path = arguments["path"]?.stringValue, !path.isEmpty else { return folder }
            return "\(folder): \(path)"
        default:
            return plain
        }
    }
}

/// What the user chose in Settings, as a value: AppSettings lives on the main actor, a call does not.
public struct BuiltInToolSettings: Sendable, Equatable {
    /// `Tool` raw values. A String list, so a name a later version adds is ignored here.
    public var enabled: [String]
    public var folderPath: String?

    public init(enabled: [String] = [], folderPath: String? = nil) {
        self.enabled = enabled
        self.folderPath = folderPath
    }

    public static let off = BuiltInToolSettings()

    /// Listed, known to this version and, for the file tools, with a folder chosen.
    public var effectiveTools: Set<BuiltInTools.Tool> {
        let hasFolder = !(folderPath ?? "").isEmpty
        return Set(enabled.compactMap(BuiltInTools.Tool.init(rawValue:)).filter { !$0.needsFolder || hasFolder })
    }
}
