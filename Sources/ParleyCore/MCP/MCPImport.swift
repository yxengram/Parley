import Foundation

// A pasted config, as the other MCP clients write them. Pure: it reads the text it is given and no
// file, and it never expands a variable. What it finds is shown for review before anything is saved.

public struct MCPImportEntry: Sendable, Identifiable {
    public var id: UUID
    /// useInNewChats false; isEnabled true unless the pasted entry says `"disabled": true`.
    public var config: MCPServerConfig
    public var secrets: MCPServerSecrets
    public var warnings: [String]
    /// What the command does that deserves a second look.
    public var danger: [String]
    /// Shown, not importable.
    public var error: String?

    public init(id: UUID = UUID(), config: MCPServerConfig, secrets: MCPServerSecrets, warnings: [String] = [],
                danger: [String] = [], error: String? = nil) {
        self.id = id
        self.config = config
        self.secrets = secrets
        self.warnings = warnings
        self.danger = danger
        self.error = error
    }
}

public enum MCPImportError: LocalizedError, Equatable {
    case notJSON
    case noServers

    public var errorDescription: String? {
        switch self {
        case .notJSON: return String(localized: "This text is not JSON.")
        case .noServers: return String(localized: "No servers found. Paste an object with mcpServers, or entries that have a command or a url.")
        }
    }
}

public enum MCPConfigImport {
    public static let singleServerName = "Imported Server"

    /// Accepts `{"mcpServers":{…}}`, `{"servers":{…}}` (VS Code), the inner map alone (what LM Studio's
    /// docs say to copy), with or without its outer braces, and one `{command|url,…}` object.
    /// Sorted by name. A name in `existingNames` gets " 2".
    public static func parse(_ text: String, existingNames: [String] = []) throws -> [MCPImportEntry] {
        guard let root = object(from: text) else { throw MCPImportError.notJSON }
        let map: [String: JSONValue]
        if case .object(let servers)? = root["mcpServers"] {
            map = servers
        } else if case .object(let servers)? = root["servers"] {
            map = servers
        } else if root["command"]?.stringValue != nil || root["url"]?.stringValue != nil {
            map = [singleServerName: .object(root)]
        } else {
            map = root
        }
        var used = Set(existingNames.map { $0.lowercased() })
        var entries: [MCPImportEntry] = []
        for name in map.keys.sorted() {
            guard case .object(let server)? = map[name] else { continue }
            guard server["command"] != nil || server["url"] != nil else { continue }
            var unique = name
            var number = 2
            while used.contains(unique.lowercased()) {
                unique = "\(name) \(number)"
                number += 1
            }
            used.insert(unique.lowercased())
            entries.append(entry(name: unique, server: server))
        }
        guard !entries.isEmpty else { throw MCPImportError.noServers }
        return entries
    }

    private static func object(from text: String) -> [String: JSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON5 mode takes the comments and trailing commas pasted configs often have.
        func parsed(_ candidate: String) -> [String: JSONValue]? {
            guard let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8), options: [.json5Allowed]) else { return nil }
            return JSONValue(any: value)?.objectValue
        }
        return parsed(trimmed) ?? parsed("{" + trimmed + "}")
    }

    private static func strings(_ value: JSONValue?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, item) in value?.objectValue ?? [:] {
            if let text = text(item) { out[key] = text }
        }
        return out
    }

    private static func text(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .double(let d): return String(d)
        default: return nil
        }
    }

    private static func entry(name: String, server: [String: JSONValue]) -> MCPImportEntry {
        var config = MCPServerConfig(name: name, isEnabled: true, useInNewChats: false)
        var secrets = MCPServerSecrets()
        var warnings: [String] = []
        var danger: [String] = []
        var problem: String?
        let type = server["type"]?.stringValue?.lowercased()

        if server["disabled"]?.boolValue == true {
            config.isEnabled = false
            warnings.append(String(localized: "Switched off in the pasted config, so it stays off here."))
        }

        if type == "sse" {
            problem = String(localized: "This server uses an older connection type (HTTP+SSE) that Parley does not support.")
        } else if let url = server["url"]?.stringValue, server["command"] == nil {
            config.kind = MCPServerConfig.kindHTTP
            secrets.url = url
            secrets.headers = strings(server["headers"])
            config.headerNames = secrets.headers.keys.sorted()
            if let host = URLComponents(string: url)?.host, !host.isEmpty,
               let scheme = URLComponents(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                config.urlHost = host
            } else {
                problem = variablePresent(url) ? String(localized: "The URL uses a variable, which Parley does not expand.") : MCPError.invalidURL.errorDescription
            }
            if let name = secrets.invalidHeaderName { problem = MCPError.invalidHeader(name).errorDescription }
            if variablePresent(secrets.headers.values) {
                warnings.append(String(localized: "A header value contains a variable such as ${VAR}. Parley keeps it literally and does not expand it: replace it in Settings > MCP after importing."))
            }
            if URLComponents(string: url)?.path.lowercased().hasSuffix("/sse") == true {
                warnings.append(String(localized: "This URL looks like an older HTTP+SSE server, which Parley does not support. It may not connect."))
            }
        } else if let command = server["command"]?.stringValue, !command.isEmpty {
            config.kind = MCPServerConfig.kindStdio
            config.command = command
            secrets.args = (server["args"]?.arrayValue ?? []).compactMap(text)
            secrets.env = strings(server["env"])
            config.envNames = secrets.env.keys.sorted()
            if let cwd = server["cwd"]?.stringValue, !cwd.isEmpty { config.workingDirectory = cwd }
            if variablePresent(secrets.args + secrets.env.values + [command]) {
                warnings.append(String(localized: "The command, an argument or an environment value contains a variable such as ${VAR}. Parley keeps it literally and does not expand it: replace it in Settings > MCP after importing."))
            }
            if command.contains(" ") {
                // The command goes to preferences, not the Keychain, so a whole command line with a
                // token in it must not be saved. A full path may hold a space.
                if command.hasPrefix("/") || command.hasPrefix("~") {
                    warnings.append(String(localized: "The command contains a space. It is run as one program name; put arguments under args."))
                } else {
                    problem = MCPError.commandNotFound(name: command, searched: []).summary
                }
            }
            danger = dangers(config: config, secrets: secrets)
        } else {
            problem = String(localized: "This entry has neither a command nor a url.")
        }

        for key in ["envFile", "auth", "oauth"] where server[key] != nil {
            warnings.append(String(localized: "\(key) is ignored: Parley reads no other files. To sign in, press Sign In in Settings > MCP."))
        }
        return MCPImportEntry(config: config, secrets: secrets, warnings: warnings, danger: danger, error: problem)
    }

    private static func variablePresent<S: Sequence>(_ values: S) -> Bool where S.Element == String {
        values.contains { $0.range(of: #"\$\{[^}]*\}"#, options: .regularExpression) != nil }
    }

    private static func variablePresent(_ value: String) -> Bool {
        variablePresent([value])
    }

    /// Variables that decide which code runs, whatever the command says. A pasted config can point
    /// `npx` at another folder's `npx`, or load a library into it.
    public static func changesWhatRuns(_ variable: String) -> Bool {
        let name = variable.uppercased()
        return name.hasPrefix("DYLD_") || name.hasPrefix("LD_") || [
            "PATH", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "BASH_ENV", "ENV", "ZDOTDIR",
            "PERL5LIB", "PERL5OPT", "RUBYLIB", "RUBYOPT", "NPM_CONFIG_REGISTRY", "UV_INDEX_URL", "UV_DEFAULT_INDEX",
            "UV_EXTRA_INDEX_URL", "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL",
        ].contains(name)
    }

    /// Plain warnings over the exact words of the command line and its environment, for the import
    /// review and the editor. Not a sandbox and not a verdict.
    public static func dangers(config: MCPServerConfig, secrets: MCPServerSecrets) -> [String] {
        guard config.kind == MCPServerConfig.kindStdio else { return [] }
        let command = config.command
        let arguments = secrets.args
        let words = [command] + arguments
        func basename(_ word: String) -> String { (word as NSString).lastPathComponent }
        // `env bash -c …` runs bash.
        var program = basename(command)
        var programArguments = arguments
        if program == "env" {
            programArguments = Array(arguments.drop { $0.hasPrefix("-") || $0.contains("=") })
            program = programArguments.first.map(basename) ?? program
            programArguments = Array(programArguments.dropFirst())
        }
        let line = words.joined(separator: " ")
        let lower = line.lowercased()
        var out: [String] = []
        func flag(_ condition: Bool, _ text: String) {
            if condition { out.append(text) }
        }
        flag(words.contains { ["sudo", "doas"].contains(basename($0)) }, String(localized: "Runs with sudo: the server would have administrator rights."))
        flag(lower.range(of: #"\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r"#, options: .regularExpression) != nil,
             String(localized: "Contains rm -rf, which deletes files without asking."))
        flag(lower.range(of: #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, options: .regularExpression) != nil,
             String(localized: "Downloads a script and runs it at once."))
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
        flag(shells.contains(program) && programArguments.contains { $0.range(of: #"^-[a-z]*c"#, options: .regularExpression) != nil },
             String(localized: "Runs a shell command line rather than a program."))
        let scripting = program.range(of: #"^(python[0-9.]*|node|deno|bun|ruby|perl)$"#, options: .regularExpression) != nil
        flag(scripting && programArguments.contains { ["-c", "-e", "-p", "--eval", "--print"].contains($0) },
             String(localized: "Runs code written into its arguments rather than a program."))
        flag(words.contains("eval") || lower.range(of: #"\beval\s"#, options: .regularExpression) != nil, String(localized: "Uses eval."))
        flag(lower.contains("chmod 777") || lower.contains("chmod -r 777"), String(localized: "Changes file permissions to world-writable (chmod 777)."))
        flag(program == "osascript", String(localized: "Runs AppleScript, which can control other apps."))
        let sensitive = ["~/.ssh", "/.ssh/", "~/.aws", "/.aws/", "~/.gnupg", "/.gnupg/", "~/library/keychains", "/library/keychains", "/etc/"]
        let touched = (words + Array(secrets.env.values)).map { $0.lowercased() }
        flag(touched.contains { word in sensitive.contains { word.contains($0) } || word == "/etc" || word.hasSuffix("/.ssh") },
             String(localized: "Points at a sensitive folder (SSH keys, cloud credentials, the Keychain or /etc)."))
        flag(touched.contains { $0 == ".env" || $0.hasSuffix("/.env") }, String(localized: "Points at a .env file, which usually holds secrets."))
        for name in secrets.env.keys.sorted() where changesWhatRuns(name) {
            out.append(String(localized: "Sets \(name)=\(secrets.env[name] ?? ""), which changes what code runs."))
        }
        return out
    }
}
