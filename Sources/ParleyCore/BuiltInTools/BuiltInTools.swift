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
        case writeFile = "write_file"
        case fetchURL = "fetch_url"
        case browseURL = "browse_url"

        /// The Settings toggle.
        public var title: String {
            switch self {
            case .currentTime: return "Current Time"
            case .calculate: return "Calculator"
            case .listFiles: return "List Files"
            case .readFile: return "Read File"
            case .writeFile: return "Write File"
            case .fetchURL: return "Fetch Web Page"
            case .browseURL: return "Browse Web Page"
            }
        }

        /// Does nothing until a folder is chosen in Settings.
        public var needsFolder: Bool { self == .listFiles || self == .readFile || self == .writeFile }

        /// Reads or writes the user's files or contacts a website, so there is no Always Allow: a page
        /// or file can tell the model to send what it read somewhere, or to write over a file, and in
        /// Manual approval each card is where that stops. (Automatic approval, a setting the user
        /// chooses, runs every call without a card: see `ToolApprovalMode`.)
        public var asksEveryTime: Bool { needsFolder || contactsWebsites }

        /// Fetch and Browse: the card names the host.
        public var contactsWebsites: Bool { self == .fetchURL || self == .browseURL }

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
                    + "folder, whose own path is \".\". Hidden files are never shown. The user may be asked to approve each call."
            case .readFile:
                return "Reads a text file (UTF-8, UTF-16 or GB18030/GBK) inside the folder the user shared. Paths are relative to that folder. "
                    + "A long file comes back in parts: the result says how to ask for the next one. Hidden files "
                    + "cannot be read. The user may be asked to approve each call."
            case .writeFile:
                return "Writes a text file, as UTF-8, inside the folder the user shared. Paths are relative to that folder; "
                    + "folders missing on the way are created. If the file exists it is replaced, and the old version is "
                    + "moved to the user's Trash. Hidden files, symlinks and folders cannot be written. At most 4 MiB. "
                    + "The user may be asked to approve each call."
            case .fetchURL:
                return "Fetches one public web page over http or https and returns its text. Scripts are not run and "
                    + "images are not loaded. Private and local addresses are refused. A redirect to another address "
                    + "is reported, not followed. The user may be asked to approve each call."
            case .browseURL:
                return "Opens one public web page over http or https in a private browser that runs its scripts, waits for "
                    + "the page to render, and returns its address, title and visible text. Use it for a page that "
                    + "fetch_url returns with little or no text because scripts build it. Slower than fetch_url. Images, "
                    + "video and fonts are not loaded, and nothing is kept afterwards. The page may load only from its "
                    + "own site unless the user has allowed other sites in Settings; the result says what was blocked. "
                    + "Private and local addresses are refused, for the page and for everything it loads. Going to "
                    + "another address is reported, not followed. The user may be asked to approve each call."
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
            case .writeFile:
                properties["path"] = string("The file, relative to the shared folder, for example notes/summary.md.")
                properties["content"] = string("The whole text of the file.")
                required = ["path", "content"]
            case .fetchURL:
                properties["url"] = string("The full http or https address.")
                required = ["url"]
            case .browseURL:
                properties["url"] = string("The full http or https address.")
                properties["links"] = .object([
                    "type": .string("boolean"),
                    "description": .string("Also list the page's links, up to \(BuiltInBrowser.maxLinks). Leave it out for text only."),
                ])
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
    /// the user, the shared folder's path and name least of all. (activate_skill is the one tool whose
    /// definition holds something of the user's: the names and descriptions of their skills.)
    public static var definitions: [MCPTool] { Tool.allCases.map(\.definition) }

    // MARK: Skills

    /// Loads one of the user's skills (see SkillManifest). Not a `Tool` case: it has no switch in
    /// Settings > Built-in Tools, and it is offered when a skill is on, not when a tool is.
    public static let skillToolName = "activate_skill"
    /// The catalog in its description lists at most this many skills, sorted by name.
    public static let maxListedSkills = 100

    /// activate_skill for these skills, which must not be empty. The catalog is in the description,
    /// as the Agent Skills client guide allows, so the system prompt stays the user's own; the names
    /// are an enum, so the model cannot ask for one that does not exist.
    public static func skillDefinition(_ skills: [SkillSummary]) -> MCPTool {
        let listed = skills.sorted { $0.name < $1.name }.prefix(maxListedSkills)
        let catalog = listed.map { "- \($0.name): \(SkillManifest.catalogDescription($0.description))" }.joined(separator: "\n")
        let description = "Loads a skill: instructions the user installed for a particular kind of task, sometimes with "
            + "files that go with them. When a request matches a skill's description below, call this with the skill's "
            + "name before you answer, then follow the instructions it returns. To read one of the skill's files, call "
            + "it again with the same name and file set to the file's path. Parley cannot run a skill's scripts or "
            + "programs.\n\nAvailable skills:\n" + catalog
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("The skill's name, as listed."),
                    "enum": .array(listed.map { .string($0.name) }),
                ]),
                "file": .object([
                    "type": .string("string"),
                    "description": .string("One of the skill's files, relative to its folder, as listed when the skill was loaded. Leave it out to load the skill's instructions."),
                ]),
                "start_line": .object([
                    "type": .string("integer"),
                    "description": .string("For a long file: the first line to return, counted from 1."),
                ]),
            ]),
            "required": .array([.string("name")]),
        ])
        return MCPTool(name: skillToolName, description: description, inputSchema: MCPSchema.normalized(schema))
    }

    /// True for an activate_skill call.
    public static func isSkillCall(_ binding: MCPToolBinding) -> Bool {
        binding.serverID == serverID && binding.tool.name == skillToolName
    }

    /// The synthetic server, or nil when nothing is on. A tool that is off is in `disabledTools`, so
    /// a reply that was already running sees it go the way it sees any other tool switched off.
    /// `tools` and `skills` are the conversation's own choices (the wrench popover). activate_skill is
    /// named in `disabledTools` only while there are skills, so with none the config is what it was
    /// before skills existed.
    public static func serverConfig(_ settings: BuiltInToolSettings, tools: Bool = true, skills: Bool = true) -> MCPServerConfig? {
        let on = tools ? settings.effectiveTools : []
        let skillsOn = skills && !settings.skills.isEmpty
        guard !on.isEmpty || skillsOn else { return nil }
        var disabled = Tool.allCases.filter { !on.contains($0) }.map(\.rawValue)
        if !settings.skills.isEmpty, !skillsOn { disabled.append(skillToolName) }
        return MCPServerConfig(id: serverID, name: serverName, kind: MCPServerConfig.kindBuiltIn, isEnabled: true,
                               disabledTools: disabled, callTimeout: callTimeout)
    }

    /// What `config` offers, under the fixed prefix. A real server's names must not depend on these
    /// switches, so on a clash with `taken` the built-in moves, to a form no server can get: a slug
    /// never starts with "_". "parley" keeps it apart in `binding(forFunctionName:)`, which ignores "_".
    /// activate_skill comes last, and only with `skills`.
    public static func bindings(for config: MCPServerConfig, avoiding taken: Set<String> = [],
                                skills: [SkillSummary] = []) -> [MCPToolBinding] {
        var tools = definitions.filter { !config.disabledTools.contains($0.name) }
        if !skills.isEmpty, !config.disabledTools.contains(skillToolName) { tools.append(skillDefinition(skills)) }
        return tools.map {
            let plain = namePrefix + "__" + $0.name
            let name = taken.contains(plain) ? namePrefix + "___parley_" + $0.name : plain
            return MCPToolBinding(exposedName: name, serverID: serverID, serverName: serverName, tool: $0)
        }
    }

    /// True only for a call of a tool that may never be remembered as allowed. activate_skill reads
    /// only what the user installed, and runs without asking (in ReAct every call asks anyway).
    public static func asksEveryTime(_ binding: MCPToolBinding) -> Bool {
        guard binding.serverID == serverID else { return false }
        if binding.tool.name == skillToolName { return false }
        return Tool(rawValue: binding.tool.name)?.asksEveryTime ?? true
    }

    /// True for a call that works in the shared folder (reading or writing), whose Allow means the
    /// folder its card named.
    public static func readsFolder(_ binding: MCPToolBinding) -> Bool {
        binding.serverID == serverID && Tool(rawValue: binding.tool.name)?.needsFolder == true
    }

    /// True for a `browse_url` call, whose Allow means the "other sites" switch as its card showed it.
    public static func dependsOnBrowseSwitch(_ binding: MCPToolBinding) -> Bool {
        binding.serverID == serverID && binding.tool.name == Tool.browseURL.rawValue
    }

    /// The line under the tool's name on the approval card. The card is local, so the folder's name
    /// may be here; it never goes to the model. The path is here too: the arguments block scrolls and
    /// the model picks its keys, so a decoy could fill what shows there and push the real one out of view.
    /// For `browse_url` it says whether the page's scripts may reach other sites (`browseOtherSites`).
    public static func approvalDetail(toolName: String, arguments: [String: JSONValue], folderPath: String?,
                                      browseOtherSites: Bool = false) -> String {
        // In the interface language: the card is the one place this is shown.
        let plain = String(localized: "Built-in tool")
        if toolName == skillToolName {
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else { return String(localized: "Built-in tool, loads a skill") }
            guard let file = arguments["file"]?.stringValue, !file.isEmpty else {
                return String(localized: "Built-in tool, loads the skill \(name)")
            }
            return String(localized: "Built-in tool, reads \(file) from the skill \(name)")
        }
        switch Tool(rawValue: toolName) {
        case .fetchURL?:
            guard let text = arguments["url"]?.stringValue, let host = BuiltInFetcher.parse(text)?.host else { return plain }
            return String(localized: "Built-in tool, contacts \(host)")
        case .browseURL?:
            guard let text = arguments["url"]?.stringValue, let host = BuiltInFetcher.parse(text)?.host else { return plain }
            return browseOtherSites
                ? String(localized: "Built-in tool, opens \(host) in a private browser; its scripts may contact other public sites")
                : String(localized: "Built-in tool, opens \(host) in a private browser, loading only from that site")
        case .writeFile?:
            guard let folderPath, !folderPath.isEmpty else { return plain }
            let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
            guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
                return String(localized: "Built-in tool, writes in folder \(folderName)")
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(arguments["content"]?.stringValue?.utf8.count ?? 0), countStyle: .file)
            // Short, with the path early: the card's line holds two lines and cuts in the middle.
            return String(localized: "Built-in tool, writes \(path) (\(size)) in folder \(folderName)")
        case let tool? where tool.needsFolder:
            guard let folderPath, !folderPath.isEmpty else { return plain }
            let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
            guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
                return String(localized: "Built-in tool, in folder \(folderName)")
            }
            return String(localized: "Built-in tool, in folder \(folderName): \(path)")
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
    /// Browse Web Page may load from other public sites, not only the approved one. Off by default.
    public var browseOtherSites: Bool
    /// The skills switched on in Settings > Skills. Empty: activate_skill is not offered.
    public var skills: [SkillSummary]

    public init(enabled: [String] = [], folderPath: String? = nil, browseOtherSites: Bool = false, skills: [SkillSummary] = []) {
        self.enabled = enabled
        self.folderPath = folderPath
        self.browseOtherSites = browseOtherSites
        self.skills = skills
    }

    public static let off = BuiltInToolSettings()

    /// Listed, known to this version and, for the file tools, with a folder chosen.
    public var effectiveTools: Set<BuiltInTools.Tool> {
        let hasFolder = !(folderPath ?? "").isEmpty
        return Set(enabled.compactMap(BuiltInTools.Tool.init(rawValue:)).filter { !$0.needsFolder || hasFolder })
    }
}
