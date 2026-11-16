import Darwin
import Foundation

public struct SkillImportLimits: Sendable {
    public var maxEntries = 2000
    public var maxTotalBytes = 100 * 1024 * 1024
    public var maxDepth = 16
    public init() {}
}

public enum SkillImportError: LocalizedError, Equatable {
    case notASkill
    case notAZip
    case unsupportedZip
    case encryptedZip
    case damagedZip
    case unsafeEntry(String)
    case tooLarge
    case tooManyFiles
    case tooDeep
    case copyFailed
    case noSkillsFolder

    public var errorDescription: String? {
        switch self {
        case .notASkill:
            return String(localized: "No skill was found there. A skill is a folder with a SKILL.md file in it, or a zip of one.")
        case .notAZip: return String(localized: "The file is not a zip archive Parley can read.")
        case .unsupportedZip: return String(localized: "This zip uses a format Parley does not read (zip64, a split archive, or a compression other than Deflate).")
        case .encryptedZip: return String(localized: "The zip is password-protected.")
        case .damagedZip: return String(localized: "The zip is damaged: a file in it does not match its checksum.")
        case .unsafeEntry(let name):
            return String(localized: "The zip holds a path that would land outside its folder, or the same path twice: \(name)")
        case .tooLarge: return String(localized: "The skill is larger than 100 MB.")
        case .tooManyFiles: return String(localized: "The skill has more than 2,000 files.")
        case .tooDeep: return String(localized: "The skill's folders are nested more than 16 levels deep.")
        case .copyFailed: return String(localized: "The skill's files could not be copied into Parley's skills folder.")
        case .noSkillsFolder: return String(localized: "Parley's skills folder could not be created.")
        }
    }
}

/// The skills folder: what is in it, adding to it and taking from it. Blocking, for a background
/// thread; nothing here touches the network or runs anything.
///
/// Parley keeps its own copies (by default ~/Library/Application Support/Parley/Skills), so what the
/// model may read is only what the user added, and a skill stays the same until the user changes it.
/// A folder the user puts there by hand is a skill too. Hidden folders are never skills: an import
/// is staged in one (".import-…") so a half-copied skill is never loaded.
public enum SkillLibrary {
    public static let maxSkills = 200

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Parley", isDirectory: true).appendingPathComponent("Skills", isDirectory: true)
    }

    // MARK: Scanning

    public struct Contents: Sendable, Equatable {
        public var skills: [Skill] = []
        public var problems: [SkillProblem] = []
        public init(skills: [Skill] = [], problems: [SkillProblem] = []) {
            self.skills = skills
            self.problems = problems
        }
    }

    /// Every skill in `root`, sorted by name. A folder without SKILL.md is not reported (it may be
    /// anything); one whose SKILL.md cannot be used is, and so is a second skill with a name taken.
    public static func scan(_ root: URL) -> Contents {
        var contents = Contents()
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        var taken: Set<String> = []
        for folder in folders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let manifest = directory.appendingPathComponent(SkillManifest.fileName)
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            guard contents.skills.count < maxSkills else {
                contents.problems.append(SkillProblem(folderName: folder, message: String(localized: "Parley loads at most 200 skills.")))
                continue
            }
            switch readManifest(manifest, folderName: folder) {
            case .problem(let message):
                contents.problems.append(SkillProblem(folderName: folder, message: message))
            case let .skill(name, description, license, compatibility, warnings):
                guard !taken.contains(name) else {
                    contents.problems.append(SkillProblem(folderName: folder, message: String(localized: "Another skill is already named \(name).")))
                    continue
                }
                taken.insert(name)
                contents.skills.append(Skill(folderName: folder, directory: directory, name: name, description: description,
                                             license: license, compatibility: compatibility, warnings: warnings))
            }
        }
        contents.skills.sort { $0.name < $1.name }
        return contents
    }

    /// The whole SKILL.md, for Settings to show. Nil when it cannot be read as text.
    public static func manifestText(of skill: Skill) -> String? {
        readText(skill.directory.appendingPathComponent(SkillManifest.fileName), limit: SkillManifest.maxFileBytes)
    }

    static func readManifest(_ url: URL, folderName: String) -> SkillManifest.Outcome {
        guard let text = readText(url, limit: SkillManifest.maxFileBytes) else {
            return .problem(String(localized: "SKILL.md could not be read as text, or is larger than 1 MB."))
        }
        return SkillManifest.read(text, folderName: folderName)
    }

    /// A regular file's UTF-8 text, nil when it is not one, is larger than `limit`, or is not text.
    static func readText(_ url: URL, limit: Int) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit,
              let data = FileManager.default.contents(atPath: url.path), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Importing

    /// An import copied into a hidden folder inside the skills folder, not yet in use.
    public struct Staged: Sendable {
        public var root: URL
        public var staging: URL
        /// The skills found, by the folder each will have.
        public var skills: [(folderName: String, name: String, source: URL)]
        /// Folders in the skills folder that installing replaces (to the Trash): one with the same
        /// folder name, or one holding a skill with the same name.
        public var conflicts: [String]
    }

    /// Copies `source` (a skill folder, a SKILL.md, a folder of skill folders, or a zip of any of
    /// these) into a hidden staging folder under `root` and finds the skills in it. Nothing is in use
    /// until `install`; `discard` removes what was staged.
    public static func stage(_ source: URL, into root: URL, limits: SkillImportLimits = SkillImportLimits()) throws -> Staged {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw SkillImportError.noSkillsFolder
        }
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw SkillImportError.noSkillsFolder }
        do {
            var picked = source
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw SkillImportError.notASkill }
            if !isDirectory.boolValue, source.lastPathComponent == SkillManifest.fileName {
                picked = source.deletingLastPathComponent()
                isDirectory = true
            }
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            if isDirectory.boolValue {
                try copyTree(from: picked, to: unpacked, limits: limits)
            } else if SkillZip.isZip(picked) {
                guard mkdir(unpacked.path, 0o700) == 0 else { throw SkillImportError.copyFailed }
                try SkillZip.extract(picked, into: unpacked, limits: limits)
            } else {
                throw SkillImportError.notASkill
            }
            let found = findSkills(in: unpacked, fallbackName: picked.deletingPathExtension().lastPathComponent)
            guard !found.isEmpty else { throw SkillImportError.notASkill }
            let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
            let current = scan(root).skills
            var conflicts: Set<String> = []
            for skill in found {
                conflicts.formUnion(folders.filter { $0.lowercased() == skill.folderName.lowercased() })
                conflicts.formUnion(current.filter { $0.name == skill.name }.map(\.folderName))
            }
            return Staged(root: root, staging: staging, skills: found, conflicts: conflicts.sorted())
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// The skill folders in what was unpacked: the top itself, or each folder one level down that
    /// has a SKILL.md (a zip of one folder, or a folder of skills). Names from the frontmatter where
    /// they make a usable folder name, otherwise the folder's own.
    private static func findSkills(in unpacked: URL, fallbackName: String) -> [(folderName: String, name: String, source: URL)] {
        func entry(_ directory: URL, folder: String) -> (folderName: String, name: String, source: URL)? {
            let manifest = directory.appendingPathComponent(SkillManifest.fileName)
            guard case let .skill(name, _, _, _, _)? = FileManager.default.fileExists(atPath: manifest.path)
                ? readManifest(manifest, folderName: folder) : nil else { return nil }
            return (folderName(for: name, fallback: folder), name, directory)
        }
        if let top = entry(unpacked, folder: fallbackName) { return [top] }
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: unpacked.path)) ?? []).sorted()
        var found: [(folderName: String, name: String, source: URL)] = []
        var usedFolders: Set<String> = []
        var usedNames: Set<String> = []
        for folder in folders where !folder.hasPrefix(".") {
            let directory = unpacked.appendingPathComponent(folder, isDirectory: true)
            if let skill = entry(directory, folder: folder), !usedFolders.contains(skill.folderName.lowercased()),
               !usedNames.contains(skill.name) {
                usedFolders.insert(skill.folderName.lowercased())
                usedNames.insert(skill.name)
                found.append(skill)
            }
        }
        return found
    }

    /// A folder name that is safe on disk: the skill's name when it is one, else a cleaned form.
    static func folderName(for name: String, fallback: String) -> String {
        if SkillManifest.isValidName(name) { return name }
        let cleaned = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "-" }
            .joined().trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if !cleaned.isEmpty, cleaned.count <= 100 { return cleaned }
        let other = fallback.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return other.isEmpty || other.contains("/") ? "skill" : String(other.prefix(100))
    }

    /// Moves the staged skills into place. A folder in the way (`conflicts`) goes to the Trash first.
    @discardableResult
    public static func install(_ staged: Staged) throws -> [String] {
        defer { discard(staged) }
        var installed: [String] = []
        for folder in staged.conflicts {
            let existing = staged.root.appendingPathComponent(folder, isDirectory: true)
            if FileManager.default.fileExists(atPath: existing.path) || isLink(existing) {
                try FileManager.default.trashItem(at: existing, resultingItemURL: nil)
            }
        }
        for skill in staged.skills {
            let target = staged.root.appendingPathComponent(skill.folderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) || isLink(target) {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
            guard rename(skill.source.path, target.path) == 0 else { throw SkillImportError.copyFailed }
            installed.append(skill.folderName)
        }
        return installed
    }

    public static func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.staging)
    }

    /// Imports left behind by a quit or a crash in the middle of one. Only at launch, when no import
    /// can be running.
    public static func removeLeftoverImports(in root: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".import-") {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Moves the skill's folder to the Trash, where the user can get it back.
    public static func moveToTrash(_ skill: Skill) throws {
        try FileManager.default.trashItem(at: skill.directory, resultingItemURL: nil)
    }

    private static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    // MARK: Copying a folder

    /// Folders and regular files only, by `lstat`: a symbolic link is skipped, never followed, so a
    /// skill cannot bring in what it points at. Hidden names, "__MACOSX", "node_modules" and
    /// "__pycache__" are left out.
    static func copyTree(from source: URL, to destination: URL, limits: SkillImportLimits) throws {
        var files = 0
        var bytes = 0
        func copy(_ from: String, _ to: String, depth: Int) throws {
            guard depth <= limits.maxDepth else { throw SkillImportError.tooDeep }
            guard mkdir(to, 0o755) == 0 else { throw SkillImportError.copyFailed }
            let names = try FileManager.default.contentsOfDirectory(atPath: from).sorted()
            for name in names where !skipped(name) {
                let child = from + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    try copy(child, to + "/" + name, depth: depth + 1)
                case S_IFREG:
                    files += 1
                    bytes += Int(info.st_size)
                    guard files <= limits.maxEntries else { throw SkillImportError.tooManyFiles }
                    guard bytes <= limits.maxTotalBytes else { throw SkillImportError.tooLarge }
                    try copyFile(child, to + "/" + name)
                default:
                    continue
                }
            }
        }
        var info = stat()
        guard stat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw SkillImportError.notASkill }
        try copy(source.path, destination.path, depth: 0)
    }

    private static func skipped(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "__MACOSX" || name == "node_modules" || name == "__pycache__"
    }

    /// Through descriptors: the source opened without following a link, the copy created new.
    private static func copyFile(_ from: String, _ to: String) throws {
        let input = open(from, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw SkillImportError.copyFailed }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SkillImportError.copyFailed }
        let output = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw SkillImportError.copyFailed }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(input, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SkillImportError.copyFailed
            }
            if n == 0 { break }
            var offset = 0
            while offset < n {
                let w = buffer.withUnsafeBytes { write(output, $0.baseAddress! + offset, n - offset) }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw SkillImportError.copyFailed
                }
                offset += w
            }
        }
    }

    // MARK: What the model may read

    /// The files of a skill other than SKILL.md, relative to its folder, sorted: what activate_skill
    /// lists so the model knows what it can ask for. Hidden files and links are left out.
    static func resources(of directory: String, limit: Int = 200) -> (paths: [String], more: Bool) {
        var found: [String] = []
        var more = false
        func walk(_ path: String, prefix: String, depth: Int) {
            guard depth <= 8, !more else { return }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
            for name in names where !skipped(name) {
                let child = path + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0, info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    walk(child, prefix: relative, depth: depth + 1)
                case S_IFREG where relative != SkillManifest.fileName:
                    if found.count >= limit { more = true; return }
                    found.append(relative)
                default:
                    continue
                }
            }
        }
        walk(directory, prefix: "", depth: 0)
        return (found, more)
    }
}
