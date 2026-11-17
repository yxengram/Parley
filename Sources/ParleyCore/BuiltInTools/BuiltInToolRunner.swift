import Foundation

/// Why a call has no answer, in words for the model. Holds nothing the model did not send itself:
/// no absolute path, no folder name.
struct BuiltInRefusal: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Set from another thread when a call stops mattering; blocking work checks it between steps.
final class BuiltInCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    var isSet: Bool { lock.withLock { set } }
    func cancel() { lock.withLock { set = true } }
}

/// Runs one built-in call. Reads the settings on every call, so a change in Settings applies to the
/// next one and a folder is never kept. All it holds is how to get them.
final class BuiltInToolRunner: Sendable {
    private let settings: @Sendable () async -> BuiltInToolSettings
    private let fetcher: BuiltInFetcher
    /// Nil where there is no app to run WebKit in: `browse_url` then says it is not available.
    private let browser: BuiltInBrowser?
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    /// Where `write_file` puts the old version of a file it replaces.
    private let trash: BuiltInFiles.Trasher

    init(settings: @escaping @Sendable () async -> BuiltInToolSettings, fetcher: BuiltInFetcher = BuiltInFetcher(),
         browser: BuiltInBrowser? = nil, trash: @escaping BuiltInFiles.Trasher = BuiltInFiles.moveToTrash,
         now: @escaping @Sendable () -> Date = { Date() }, timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
        self.settings = settings
        self.fetcher = fetcher
        self.browser = browser
        self.trash = trash
        self.now = now
        self.timeZone = timeZone
    }

    /// Never throws. Results take the same way as an MCP tool's, through ToolResultProjection, so
    /// truncation, an empty answer and errors read the same to the model.
    func call(_ tool: MCPTool, arguments: [String: JSONValue], timeout: TimeInterval, maxCharacters: Int) async -> ToolCallResult {
        let started = Date()
        var result = await run(tool, arguments: arguments, timeout: timeout, maxCharacters: maxCharacters)
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private func run(_ tool: MCPTool, arguments: [String: JSONValue], timeout: TimeInterval, maxCharacters: Int) async -> ToolCallResult {
        if tool.name == BuiltInTools.skillToolName {
            return await skill(tool, arguments: arguments, timeout: timeout, maxCharacters: maxCharacters)
        }
        guard let builtIn = BuiltInTools.Tool(rawValue: tool.name) else {
            return ToolCallResult(status: .notCalled, text: ToolResultText.unknownTool(tool.name))
        }
        let current = await settings()
        // The reply loop checked this before the card; Settings may have moved since.
        guard current.effectiveTools.contains(builtIn) else {
            return ToolCallResult(status: .notCalled, text: ToolResultText.turnedOff)
        }
        if Task.isCancelled { return ToolCallResult(status: .notCalled, text: ToolResultText.notRun) }

        let answer: BuiltInAnswer
        switch builtIn {
        case .currentTime:
            answer = .text(Self.timeText(now(), zone: timeZone()))
        case .calculate:
            answer = Self.calculate(arguments)
        case .listFiles, .readFile, .writeFile:
            let files = BuiltInFiles(rootPath: current.folderPath ?? "", trash: trash)
            answer = await Self.race(timeout: timeout) { await Self.onOwnThread { cancel in
                Self.fileAnswer(builtIn, files: files, arguments: arguments, maxCharacters: maxCharacters, cancel: cancel)
            } }
        case .fetchURL:
            let fetcher = self.fetcher
            answer = await Self.race(timeout: timeout) { await fetcher.fetch(arguments["url"]?.stringValue) }
        case .browseURL:
            if let browser {
                let otherSites = current.browseOtherSites
                answer = await Self.race(timeout: timeout) {
                    await browser.browse(arguments, budget: maxCharacters, otherSites: otherSites)
                }
            } else {
                answer = .error("Browse Web Page is not available here.")
            }
        }

        switch answer {
        case .text(let text): return project(text, isError: false, maxCharacters: maxCharacters)
        case .error(let text): return project(text, isError: true, maxCharacters: maxCharacters)
        case .cancelled: return ToolCallResult(status: .cancelled, text: ToolResultText.interrupted)
        case .timedOut: return ToolCallResult(status: .timedOut, text: ToolResultText.timedOut(seconds: timeout))
        }
    }

    private func project(_ text: String, isError: Bool, maxCharacters: Int) -> ToolCallResult {
        ToolResultProjection.project(result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ]), maxCharacters: maxCharacters)
    }

    // MARK: activate_skill

    private func skill(_ tool: MCPTool, arguments: [String: JSONValue], timeout: TimeInterval, maxCharacters: Int) async -> ToolCallResult {
        let current = await settings()
        // Skills switched off, or all removed, since the reply began.
        guard !current.skills.isEmpty else { return ToolCallResult(status: .notCalled, text: ToolResultText.turnedOff) }
        // One that this reply offered (its definition's enum) but that is off or gone now.
        if let name = arguments["name"]?.stringValue, !current.skills.contains(where: { $0.name == name }),
           Self.offeredSkillNames(tool).contains(name) {
            return ToolCallResult(status: .notCalled, text: ToolResultText.turnedOff)
        }
        if Task.isCancelled { return ToolCallResult(status: .notCalled, text: ToolResultText.notRun) }
        let answer: BuiltInAnswer
        if let name = arguments["name"]?.stringValue, let found = current.skills.first(where: { $0.name == name }) {
            answer = await Self.race(timeout: timeout) { await Self.onOwnThread { cancel in
                Self.skillAnswer(found, arguments: arguments, maxCharacters: maxCharacters, cancel: cancel)
            } }
        } else if arguments["name"]?.stringValue == nil {
            answer = .error("`name` must be a string: one of the skills listed in this tool's description.")
        } else {
            let names = current.skills.map(\.name).sorted().prefix(BuiltInTools.maxListedSkills).joined(separator: ", ")
            answer = .error("There is no skill named \"\(arguments["name"]?.stringValue ?? "")\". The skills are: \(names).")
        }
        switch answer {
        case .text(let text): return project(text, isError: false, maxCharacters: maxCharacters)
        case .error(let text): return project(text, isError: true, maxCharacters: maxCharacters)
        case .cancelled: return ToolCallResult(status: .cancelled, text: ToolResultText.interrupted)
        case .timedOut: return ToolCallResult(status: .timedOut, text: ToolResultText.timedOut(seconds: timeout))
        }
    }

    /// The names in the definition the reply offered: the `name` parameter's enum.
    static func offeredSkillNames(_ tool: MCPTool) -> Set<String> {
        let names = tool.inputSchema.objectValue?["properties"]?.objectValue?["name"]?.objectValue?["enum"]?.arrayValue ?? []
        return Set(names.compactMap(\.stringValue))
    }

    /// SKILL.md's instructions (frontmatter left out) with the list of the skill's other files, or one
    /// of those files. Everything is read through BuiltInFiles rooted at the skill's folder, so a link
    /// in a skill the user put there by hand cannot lead out of it.
    static func skillAnswer(_ skill: SkillSummary, arguments: [String: JSONValue], maxCharacters: Int,
                            cancel: BuiltInCancelFlag) -> BuiltInAnswer {
        var files = BuiltInFiles(rootPath: skill.directoryPath)
        files.wording = .skillFolder
        do {
            if let value = arguments["file"], !value.isNull {
                guard let path = value.stringValue else { return .error("`file` must be a string.") }
                if !path.isEmpty {
                    var startLine = 1
                    if let value = arguments["start_line"], !value.isNull {
                        guard let number = value.intValue, number >= 1, number <= Int32.max else {
                            return .error("`start_line` must be a whole number, 1 or more.")
                        }
                        startLine = Int(number)
                    }
                    return .text(try files.read(path: path, startLine: startLine, maxCharacters: maxCharacters, cancel: cancel))
                }
            }
            // The whole of SKILL.md (one page as large as the result may be), then its body.
            let text = try files.read(path: SkillManifest.fileName, startLine: 1, maxCharacters: Int.max / 2, cancel: cancel)
            let body = SkillManifest.parse(text)?.body ?? text
            if cancel.isSet { return .cancelled }
            let (resources, more) = SkillLibrary.resources(of: skill.directoryPath)
            return .text(skillText(name: skill.name, body: body, resources: resources, more: more))
        } catch let refusal as BuiltInRefusal {
            return .error(refusal.message)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .error("The skill could not be read.")
        }
    }

    /// The wrapping the Agent Skills client guide suggests, so the model can tell the skill's text
    /// from the rest of the conversation. The folder's path is not given: files are asked for by name.
    static func skillText(name: String, body: String, resources: [String], more: Bool) -> String {
        let attribute = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
        var out = "<skill_content name=\"\(attribute)\">\n\(body)\n\n"
        if resources.isEmpty {
            out += "[Parley cannot run scripts or programs.]\n"
        } else {
            out += "[The skill's files are listed below, relative to its folder. To read one, call activate_skill again "
                + "with this name and file set to its path. Parley cannot run scripts or programs: read a script to see "
                + "what it does, or tell the user what to run.]\n\n<skill_resources>\n"
            out += resources.map { "<file>\($0)</file>" }.joined(separator: "\n")
            if more { out += "\n[More files are not listed.]" }
            out += "\n</skill_resources>\n"
        }
        return out + "</skill_content>"
    }

    // MARK: The tools that need no waiting

    static func timeText(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE xxx"
        let parts = formatter.string(from: date).split(separator: " ").map(String.init)
        return "Date: \(parts[0])\nTime: \(parts[1])\nWeekday: \(parts[2])\nUTC offset: \(parts[3])\nTime zone: \(zone.identifier)"
    }

    private static func calculate(_ arguments: [String: JSONValue]) -> BuiltInAnswer {
        guard let expression = arguments["expression"]?.stringValue else { return .error("`expression` must be a string.") }
        do {
            return .text(BuiltInCalculator.format(try BuiltInCalculator.evaluate(expression)))
        } catch let failure as BuiltInCalculator.Failure {
            return .error(failure.message)
        } catch {
            return .error("The expression could not be evaluated.")
        }
    }

    private static func fileAnswer(_ tool: BuiltInTools.Tool, files: BuiltInFiles, arguments: [String: JSONValue],
                                   maxCharacters: Int, cancel: BuiltInCancelFlag) -> BuiltInAnswer {
        do {
            if tool == .listFiles {
                if let path = arguments["path"], !path.isNull, path.stringValue == nil { return .error("`path` must be a string.") }
                return .text(try files.list(path: arguments["path"]?.stringValue, cancel: cancel))
            }
            guard let path = arguments["path"]?.stringValue else { return .error("`path` must be a string.") }
            if tool == .writeFile {
                guard let content = arguments["content"]?.stringValue else { return .error("`content` must be a string.") }
                return .text(try files.write(path: path, content: content, cancel: cancel))
            }
            var startLine = 1
            if let value = arguments["start_line"], !value.isNull {
                guard let number = value.intValue, number >= 1, number <= Int32.max else {
                    return .error("`start_line` must be a whole number, 1 or more.")
                }
                startLine = Int(number)
            }
            return .text(try files.read(path: path, startLine: startLine, maxCharacters: maxCharacters, cancel: cancel))
        } catch let refusal as BuiltInRefusal {
            return .error(refusal.message)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .error(tool == .writeFile ? "The file could not be written." : "The file could not be read.")
        }
    }

    // MARK: Waiting

    /// Off the cooperative pool: a read can block for as long as the disk or network likes.
    private static func onOwnThread(_ work: @escaping @Sendable (BuiltInCancelFlag) -> BuiltInAnswer) async -> BuiltInAnswer {
        let flag = BuiltInCancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work(flag)) }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// First of the work, the timeout and cancellation. The caller goes on at once even if the work
    /// does not (a DNS lookup or a blocked read cannot be interrupted); it is cancelled, and what
    /// it ends up with is dropped. A task group would wait for it, and Stop along with it.
    private static func race(timeout: TimeInterval, _ work: @escaping @Sendable () async -> BuiltInAnswer) async -> BuiltInAnswer {
        let first = FirstAnswer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                first.wait(continuation)
                let worker = Task { first.finish(await work()) }
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    if !Task.isCancelled { first.finish(.timedOut) }
                }
                first.onFinish {
                    worker.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            first.finish(.cancelled)
        }
    }
}

enum BuiltInAnswer: Sendable, Equatable {
    case text(String)
    /// The tool ran and reports a failure.
    case error(String)
    case cancelled
    case timedOut
}

/// One answer, however many arrive, and it may arrive before anyone waits for it.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: BuiltInAnswer?
    private var continuation: CheckedContinuation<BuiltInAnswer, Never>?
    private var cleanup: (@Sendable () -> Void)?

    func wait(_ waiting: CheckedContinuation<BuiltInAnswer, Never>) {
        let ready: BuiltInAnswer? = lock.withLock {
            if answer == nil { continuation = waiting }
            return answer
        }
        if let ready { waiting.resume(returning: ready) }
    }

    func onFinish(_ work: @escaping @Sendable () -> Void) {
        let done: Bool = lock.withLock {
            if answer == nil { cleanup = work }
            return answer != nil
        }
        if done { work() }
    }

    func finish(_ value: BuiltInAnswer) {
        let (waiting, work): (CheckedContinuation<BuiltInAnswer, Never>?, (@Sendable () -> Void)?) = lock.withLock {
            guard answer == nil else { return (nil, nil) }
            answer = value
            defer { continuation = nil; cleanup = nil }
            return (continuation, cleanup)
        }
        work?()
        waiting?.resume(returning: value)
    }
}
