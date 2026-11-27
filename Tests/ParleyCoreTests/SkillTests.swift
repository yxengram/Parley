import Compression
import Foundation
import Testing
@testable import ParleyCore

// Skills in the core: reading SKILL.md, the zip reader, the skills folder, and activate_skill. Every
// file is in a temp folder of the test's own; nothing moves to the Trash and nothing reads the
// user's skills.

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ParleySkillTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeSkill(_ root: URL, folder: String, manifest: String, files: [String: String] = [:]) throws -> URL {
    let dir = root.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try manifest.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    for (path, text) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

private func manifest(_ name: String, _ description: String, body: String = "Do the thing.") -> String {
    "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n"
}

// MARK: - A tiny zip writer for the tests

private struct ZipItem {
    var name: String
    var data: Data = Data()
    var deflate = true
    var symlink = false
    var encrypted = false
    var badCRC = false
}

private func makeZip(_ items: [ZipItem]) -> Data {
    func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    var out: [UInt8] = []
    var central: [UInt8] = []
    for item in items {
        let name = Array(item.name.utf8)
        var payload = [UInt8](item.data)
        var method = 0
        if item.deflate, !item.data.isEmpty {
            var buffer = [UInt8](repeating: 0, count: item.data.count + 1024)
            let n = item.data.withUnsafeBytes {
                compression_encode_buffer(&buffer, buffer.count, $0.bindMemory(to: UInt8.self).baseAddress!, item.data.count, nil, COMPRESSION_ZLIB)
            }
            payload = Array(buffer.prefix(n))
            method = 8
        }
        var crc = SkillZip.crc32(item.data)
        if item.badCRC { crc ^= 1 }
        let flags = item.encrypted ? 1 : 0
        let offset = UInt32(out.count)
        out += u32(0x0403_4B50) + u16(20) + u16(flags) + u16(method) + u16(0) + u16(0) + u32(crc)
            + u32(UInt32(payload.count)) + u32(UInt32(item.data.count)) + u16(name.count) + u16(0) + name + payload
        let madeBy = item.symlink ? (3 << 8) | 20 : 20
        let external: UInt32 = item.symlink ? UInt32(0o120777) << 16 : 0
        central += u32(0x0201_4B50) + u16(madeBy) + u16(20) + u16(flags) + u16(method) + u16(0) + u16(0) + u32(crc)
            + u32(UInt32(payload.count)) + u32(UInt32(item.data.count)) + u16(name.count) + u16(0) + u16(0)
            + u16(0) + u16(0) + u32(external) + u32(offset) + name
    }
    let centralOffset = UInt32(out.count)
    out += central
    out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(items.count) + u16(items.count) + u32(UInt32(central.count))
        + u32(centralOffset) + u16(0)
    return Data(out)
}

private func zipFile(_ root: URL, _ items: [ZipItem], name: String = "skill.zip") throws -> URL {
    let url = root.appendingPathComponent(name)
    try makeZip(items).write(to: url)
    return url
}

// MARK: - SKILL.md

@Suite struct SkillManifestTests {
    @Test func aPlainManifest() throws {
        let parsed = try #require(SkillManifest.parse(manifest("pdf", "Reads PDFs.", body: "# PDF\n\nSteps.")))
        #expect(parsed.fields["name"] == "pdf")
        #expect(parsed.fields["description"] == "Reads PDFs.")
        #expect(parsed.body == "# PDF\n\nSteps.")
    }

    @Test func blockScalarsQuotesAndColons() throws {
        let text = """
        \u{FEFF}---\r
        name: "data-analysis"\r
        description: >\r
          Analyses data sets\r
          and draws charts.\r
        license: 'MIT, see ''LICENSE'''\r
        notes: |\r
          line one\r
          line two\r
        compatibility: Use this when: the user asks # a comment\r
        metadata:\r
          author: example-org\r
          version: "1.0"\r
        ---\r
        Body\r
        """
        let parsed = try #require(SkillManifest.parse(text))
        #expect(parsed.fields["name"] == "data-analysis")
        #expect(parsed.fields["description"] == "Analyses data sets and draws charts.\n")
        #expect(parsed.fields["license"] == "MIT, see 'LICENSE'")
        #expect(parsed.fields["notes"] == "line one\nline two\n")
        #expect(parsed.fields["compatibility"] == "Use this when: the user asks")
        #expect(parsed.maps["metadata"] == ["author": "example-org", "version": "1.0"])
        #expect(parsed.body == "Body")
    }

    @Test func aScalarOnTheLineAfterTheKeyIsTheValue() throws {
        let a = try #require(SkillManifest.parse("---\nname: x\ndescription:\n  Use when you need x\n  and y\n---\n"))
        #expect(a.fields["description"] == "Use when you need x and y")
        let b = try #require(SkillManifest.parse("---\nname: x\ndescription:\n  Use when: x\nmetadata:\n  author: me\n---\n"))
        #expect(b.fields["description"] == "Use when: x")
        #expect(b.maps["metadata"] == ["author": "me"])
    }

    @Test func aTrailingCommentAfterAQuotedValueIsNotTheValue() throws {
        let p = try #require(SkillManifest.parse("---\nname: \"my-skill\" # x\ndescription: 'It''s' # n\n---\n"))
        #expect(p.fields["name"] == "my-skill")
        #expect(p.fields["description"] == "It's")
    }

    @Test func escapesInDoubleQuotesIncludeSurrogatePairs() throws {
        let p = try #require(SkillManifest.parse("---\nname: x\ndescription: \"Hi \\ud83d\\ude00 \\U0001F600 \\x41 there\"\n---\n"))
        #expect(p.fields["description"] == "Hi \u{1F600} \u{1F600} A there")
    }

    @Test func anIndentedMarkerInABlockScalarIsContent() throws {
        let p = try #require(SkillManifest.parse("---\nname: x\ndescription: |\n  line1\n  ---\n  line2\n---\nBody"))
        #expect(p.fields["description"] == "line1\n---\nline2\n")
        #expect(p.body == "Body")
    }

    @Test func aPlainValueGoesOnOverIndentedLines() throws {
        let parsed = try #require(SkillManifest.parse("---\nname: x\ndescription: one\n  two\n  three\n---\n"))
        #expect(parsed.fields["description"] == "one two three")
    }

    @Test func escapesInDoubleQuotes() throws {
        let parsed = try #require(SkillManifest.parse(#"---\#ndescription: "a \"b\" \u00e9\n"\#n---\#n"#))
        #expect(parsed.fields["description"] == "a \"b\" é\n")
    }

    @Test func noFrontmatterIsNoManifest() {
        #expect(SkillManifest.parse("# Just markdown") == nil)
        #expect(SkillManifest.parse("---\nname: x\n") == nil, "no closing line")
    }

    @Test func names() {
        for good in ["pdf", "pdf-processing", "a1", String(repeating: "a", count: 64)] { #expect(SkillManifest.isValidName(good), "\(good)") }
        for bad in ["", "PDF", "-pdf", "pdf-", "pdf--x", "pdf x", "pdf_x", String(repeating: "a", count: 65), "pdé"] {
            #expect(!SkillManifest.isValidName(bad), "\(bad)")
        }
    }

    @Test func leniency() {
        guard case let .skill(name, _, _, _, warnings) = SkillManifest.read(manifest("Code Review", "Reviews."), folderName: "code") else {
            Issue.record("should load"); return
        }
        #expect(name == "Code Review")
        #expect(warnings.count == 2, "bad name, and not the folder's")

        guard case let .skill(fallback, _, _, _, missing) = SkillManifest.read("---\ndescription: d\n---\n", folderName: "folder") else {
            Issue.record("should load"); return
        }
        #expect(fallback == "folder" && missing.count == 1)

        if case .skill = SkillManifest.read("---\nname: x\n---\nbody", folderName: "x") { Issue.record("no description must not load") }
        if case .skill = SkillManifest.read("no frontmatter", folderName: "x") { Issue.record("no frontmatter must not load") }

        guard case let .skill(_, _, _, _, tools) = SkillManifest.read("---\nname: x\ndescription: d\nallowed-tools: Bash(git:*)\n---\n", folderName: "x") else {
            Issue.record("should load"); return
        }
        #expect(tools.count == 1, "allowed-tools is reported as ignored")
    }

    @Test func theCatalogDescriptionIsOneCappedLine() {
        #expect(SkillManifest.catalogDescription("a\n\n b  \n") == "a b")
        #expect(SkillManifest.catalogDescription(String(repeating: "x", count: 2000)).count == 1024)
    }
}

// MARK: - The skills folder

@Suite struct SkillLibraryTests {
    @Test func scanFindsSkillsSortedAndReportsProblems() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(root, folder: "zeta", manifest: manifest("zeta", "Last."))
        try writeSkill(root, folder: "alpha", manifest: manifest("alpha", "First."))
        try writeSkill(root, folder: "copy", manifest: manifest("alpha", "Same name."))
        try writeSkill(root, folder: "broken", manifest: "---\nname: broken\n---\n")
        try writeSkill(root, folder: ".hidden", manifest: manifest("hidden", "Never."))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)

        let contents = SkillLibrary.scan(root)
        #expect(contents.skills.map(\.name) == ["alpha", "zeta"])
        #expect(Set(contents.problems.map(\.folderName)) == ["broken", "copy"])
        #expect(SkillLibrary.scan(root.appendingPathComponent("missing")) == SkillLibrary.Contents())
    }

    @Test func importingAFolderCopiesOnlyFilesAndFolders() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSkill(root, folder: "source/my-skill", manifest: manifest("my-skill", "Mine."),
                                    files: ["references/a.md": "A", ".git/config": "secret", "node_modules/x.js": "x"])
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        let skills = root.appendingPathComponent("Skills", isDirectory: true)

        let staged = try SkillLibrary.stage(source, into: skills)
        #expect(staged.skills.map(\.folderName) == ["my-skill"] && staged.conflicts.isEmpty)
        #expect(SkillLibrary.scan(skills).skills.isEmpty, "a staged import is not loaded")
        try SkillLibrary.install(staged)

        let installed = skills.appendingPathComponent("my-skill")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("references/a.md").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent(".git").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("node_modules").path))
        var info = stat()
        #expect(lstat(installed.appendingPathComponent("link").path, &info) != 0, "links are not copied")
        #expect(SkillLibrary.scan(skills).skills.map(\.name) == ["my-skill"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: skills.path)
        #expect(leftovers == ["my-skill"], "the staging folder is gone")

        // The same skill again is a conflict, found before anything is replaced.
        let again = try SkillLibrary.stage(source, into: skills)
        #expect(again.conflicts == ["my-skill"])
        SkillLibrary.discard(again)
        #expect(try FileManager.default.contentsOfDirectory(atPath: skills.path) == ["my-skill"])
    }

    /// A skill with the same name in a folder of another name is replaced too, or the old one would
    /// keep loading and the new one would sit under "Not Loaded". Only `stage` runs: nothing goes to
    /// the Trash in a test.
    @Test func aSkillOfTheSameNameInAnotherFolderIsAConflict() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("Skills", isDirectory: true)
        try writeSkill(skills, folder: "my-notes", manifest: manifest("release-notes", "Old."))
        try writeSkill(skills, folder: "other", manifest: manifest("other", "Other."))
        let source = try writeSkill(root, folder: "src/release-notes", manifest: manifest("release-notes", "New."))
        let staged = try SkillLibrary.stage(source, into: skills)
        #expect(staged.conflicts == ["my-notes"])
        SkillLibrary.discard(staged)

        // Two skills of one name in one import: the first is taken.
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try writeSkill(bundle, folder: "a", manifest: manifest("same", "A."))
        try writeSkill(bundle, folder: "b", manifest: manifest("same", "B."))
        let twice = try SkillLibrary.stage(bundle, into: skills)
        #expect(twice.skills.map(\.name) == ["same"])
        SkillLibrary.discard(twice)
    }

    @Test func leftoverImportsAreRemoved() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".import-x/unpacked"), withIntermediateDirectories: true)
        try writeSkill(root, folder: "kept", manifest: manifest("kept", "K."))
        SkillLibrary.removeLeftoverImports(in: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["kept"])
    }

    @Test func aSkillMdOrAFolderOfSkillsImportsToo() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try writeSkill(bundle, folder: "one", manifest: manifest("one", "1."))
        try writeSkill(bundle, folder: "two", manifest: manifest("two", "2."))
        let skills = root.appendingPathComponent("Skills", isDirectory: true)
        try SkillLibrary.install(try SkillLibrary.stage(bundle, into: skills))
        #expect(SkillLibrary.scan(skills).skills.map(\.name) == ["one", "two"])

        let single = try writeSkill(root, folder: "loose", manifest: manifest("Odd Name!", "Odd."))
        let staged = try SkillLibrary.stage(single.appendingPathComponent("SKILL.md"), into: skills)
        #expect(staged.skills.map(\.folderName) == ["Odd-Name"], "a usable folder name")
        SkillLibrary.discard(staged)
    }

    @Test func somethingElseIsNotASkill() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let skills = root.appendingPathComponent("Skills", isDirectory: true)
        #expect(throws: SkillImportError.notASkill) { try SkillLibrary.stage(text, into: skills) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: SkillImportError.notASkill) { try SkillLibrary.stage(empty, into: skills) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: skills.path).isEmpty, "nothing left behind")
    }

    @Test func limitsAreKept() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSkill(root, folder: "big", manifest: manifest("big", "Big."), files: ["a": "1", "b": "2", "c": "3"])
        var limits = SkillImportLimits()
        limits.maxEntries = 2
        #expect(throws: SkillImportError.tooManyFiles) { try SkillLibrary.stage(source, into: root.appendingPathComponent("S"), limits: limits) }
        limits = SkillImportLimits()
        limits.maxTotalBytes = 10
        #expect(throws: SkillImportError.tooLarge) { try SkillLibrary.stage(source, into: root.appendingPathComponent("S"), limits: limits) }
    }

    @Test func resourcesAreRelativeSortedAndSkipHiddenFiles() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeSkill(root, folder: "s", manifest: manifest("s", "S."),
                                 files: ["scripts/run.py": "", "references/b.md": "", "references/a.md": "", ".secret": ""])
        let (paths, more) = SkillLibrary.resources(of: dir.path)
        #expect(paths == ["references/a.md", "references/b.md", "scripts/run.py"] && !more)
        #expect(SkillLibrary.resources(of: dir.path, limit: 2).more)
    }
}

// MARK: - Zip

@Suite struct SkillZipTests {
    private let body = Data(manifest("zipped", "From a zip.").utf8)

    @Test func aZipOfOneFolderImports() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try zipFile(root, [
            ZipItem(name: "zipped/"), ZipItem(name: "zipped/SKILL.md", data: body),
            ZipItem(name: "zipped/references/notes.md", data: Data("notes".utf8), deflate: false),
            ZipItem(name: "__MACOSX/zipped/._SKILL.md", data: Data("x".utf8)),
            ZipItem(name: "zipped/.DS_Store", data: Data("x".utf8)),
            ZipItem(name: "zipped/link", data: Data("/etc/passwd".utf8), deflate: false, symlink: true),
        ], name: "zipped.skill")
        #expect(SkillZip.isZip(zip))
        let skills = root.appendingPathComponent("Skills", isDirectory: true)
        try SkillLibrary.install(try SkillLibrary.stage(zip, into: skills))
        let dir = skills.appendingPathComponent("zipped")
        #expect(try String(contentsOf: dir.appendingPathComponent("references/notes.md"), encoding: .utf8) == "notes")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("link").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path))
        #expect(!FileManager.default.fileExists(atPath: skills.appendingPathComponent("__MACOSX").path))
        #expect(SkillLibrary.scan(skills).skills.map(\.name) == ["zipped"])
    }

    @Test func aZipWithSkillMdAtTheTopImports() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try zipFile(root, [ZipItem(name: "SKILL.md", data: body)])
        let staged = try SkillLibrary.stage(zip, into: root.appendingPathComponent("Skills"))
        #expect(staged.skills.map(\.folderName) == ["zipped"])
        SkillLibrary.discard(staged)
    }

    @Test(arguments: ["../evil", "a/../../evil", "/etc/evil", "C:\\evil", "..\\evil"])
    func entriesThatLeaveAreRefused(name: String) throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try zipFile(root, [ZipItem(name: "SKILL.md", data: body), ZipItem(name: name, data: Data("x".utf8))])
        #expect(throws: SkillImportError.unsafeEntry(name)) { try SkillLibrary.stage(zip, into: root.appendingPathComponent("Skills")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Skills").path).isEmpty)
    }

    @Test func damagedEncryptedTwiceAndTooLarge() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = root.appendingPathComponent("Skills")
        let bad = try zipFile(root, [ZipItem(name: "SKILL.md", data: body, badCRC: true)], name: "bad.zip")
        #expect(throws: SkillImportError.damagedZip) { try SkillLibrary.stage(bad, into: skills) }
        let locked = try zipFile(root, [ZipItem(name: "SKILL.md", data: body, encrypted: true)], name: "locked.zip")
        #expect(throws: SkillImportError.encryptedZip) { try SkillLibrary.stage(locked, into: skills) }
        let twice = try zipFile(root, [ZipItem(name: "SKILL.md", data: body), ZipItem(name: "SKILL.md", data: body)], name: "twice.zip")
        #expect(throws: SkillImportError.unsafeEntry("SKILL.md")) { try SkillLibrary.stage(twice, into: skills) }
        var limits = SkillImportLimits()
        limits.maxTotalBytes = 10
        let big = try zipFile(root, [ZipItem(name: "SKILL.md", data: body)], name: "big.zip")
        #expect(throws: SkillImportError.tooLarge) { try SkillLibrary.stage(big, into: skills, limits: limits) }
        let notZip = root.appendingPathComponent("fake.zip")
        try Data("PK\u{3}\u{4}garbage".utf8).write(to: notZip)
        #expect(throws: SkillImportError.notAZip) { try SkillLibrary.stage(notZip, into: skills) }
    }

    /// The archives macOS itself makes (Finder's Compress uses ditto): deflated, with data descriptors.
    @Test func aZipMadeByDittoImports() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSkill(root, folder: "src/ditto-skill", manifest: manifest("ditto-skill", "Zipped by ditto."),
                                    files: ["references/long.md": String(repeating: "All work and no play. ", count: 2000)])
        let zip = root.appendingPathComponent("ditto-skill.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let skills = root.appendingPathComponent("Skills", isDirectory: true)
        try SkillLibrary.install(try SkillLibrary.stage(zip, into: skills))
        let long = try String(contentsOf: skills.appendingPathComponent("ditto-skill/references/long.md"), encoding: .utf8)
        #expect(long.count == 22 * 2000)
    }
}

// MARK: - activate_skill

@Suite struct SkillToolTests {
    private func summary(_ dir: URL, _ name: String = "release-notes") -> SkillSummary {
        SkillSummary(name: name, description: "Writes release notes.", directoryPath: dir.path)
    }

    @Test func withNoSkillsNothingChanges() throws {
        let plain = BuiltInToolSettings(enabled: ["calculate"])
        let config = try #require(BuiltInTools.serverConfig(plain))
        #expect(config.disabledTools == BuiltInTools.Tool.allCases.filter { $0 != .calculate }.map(\.rawValue))
        #expect(BuiltInTools.bindings(for: config).map(\.exposedName) == ["builtin__calculate"])
        #expect(BuiltInTools.serverConfig(.off) == nil)
        #expect(BuiltInTools.serverConfig(BuiltInToolSettings(), skills: true) == nil)
    }

    @Test func skillsAloneMakeTheServerAndComeLast() throws {
        let skills = [SkillSummary(name: "b", description: "Second.", directoryPath: "/x/b"),
                      SkillSummary(name: "a", description: "First\nline.", directoryPath: "/x/a")]
        let settings = BuiltInToolSettings(enabled: ["current_time"], skills: skills)
        let config = try #require(BuiltInTools.serverConfig(settings))
        let bindings = BuiltInTools.bindings(for: config, skills: skills)
        #expect(bindings.map(\.exposedName) == ["builtin__current_time", "builtin__activate_skill"])
        let tool = try #require(bindings.last?.tool)
        #expect(tool.description?.contains("- a: First line.\n- b: Second.") == true)
        #expect(tool.description?.contains("/x/") == false, "no path goes to the model")
        let names = tool.inputSchema.objectValue?["properties"]?.objectValue?["name"]?.objectValue?["enum"]
        #expect(names == .array([.string("a"), .string("b")]))

        // Tools off for this conversation, skills still on.
        let skillsOnly = try #require(BuiltInTools.serverConfig(settings, tools: false))
        #expect(BuiltInTools.bindings(for: skillsOnly, skills: skills).map(\.exposedName) == ["builtin__activate_skill"])
        // Skills off: named as off, so a running reply sees it go.
        let toolsOnly = try #require(BuiltInTools.serverConfig(settings, skills: false))
        #expect(toolsOnly.disabledTools.contains(BuiltInTools.skillToolName))
        #expect(BuiltInTools.bindings(for: toolsOnly, skills: skills).map(\.exposedName) == ["builtin__current_time"])
        #expect(BuiltInTools.serverConfig(settings, tools: false, skills: false) == nil)

        let binding = try #require(bindings.last)
        #expect(!BuiltInTools.asksEveryTime(binding) && BuiltInTools.isSkillCall(binding))
    }

    @Test func theCatalogIsCapped() {
        let many = (0..<150).map { SkillSummary(name: String(format: "s%03d", $0), description: "d", directoryPath: "/x") }
        let tool = BuiltInTools.skillDefinition(many)
        #expect(tool.description?.components(separatedBy: "\n- ").count == BuiltInTools.maxListedSkills + 1, "the text before the first, then one per skill")
    }

    @Test func loadingASkillGivesItsBodyAndFiles() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeSkill(root, folder: "release-notes", manifest: manifest("release-notes", "Notes.", body: "# Notes\n\nGroup the changes."),
                                 files: ["templates/notes.md": "## New\nline 2\nline 3", ".env": "secret"])
        let settings = BuiltInToolSettings(skills: [summary(dir)])
        let runner = BuiltInToolRunner(settings: { settings })
        let tool = BuiltInTools.skillDefinition(settings.skills)

        let loaded = await runner.call(tool, arguments: ["name": .string("release-notes")], timeout: 5, maxCharacters: 10_000)
        #expect(loaded.callStatus == .completed)
        #expect(loaded.text.hasPrefix("<skill_content name=\"release-notes\">\n# Notes\n\nGroup the changes."))
        #expect(!loaded.text.contains("description:"), "the frontmatter is left out")
        #expect(loaded.text.contains("<file>templates/notes.md</file>") && !loaded.text.contains(".env"))
        #expect(!loaded.text.contains(root.path), "no path goes to the model")

        let file = await runner.call(tool, arguments: ["name": .string("release-notes"), "file": .string("templates/notes.md"),
                                                       "start_line": .int(2)], timeout: 5, maxCharacters: 10_000)
        #expect(file.text.hasPrefix("line 2\nline 3"))

        let outside = await runner.call(tool, arguments: ["name": .string("release-notes"), "file": .string("../x")], timeout: 5, maxCharacters: 10_000)
        #expect(outside.callStatus == .toolError && outside.text.contains("the skill's folder"))
        let hidden = await runner.call(tool, arguments: ["name": .string("release-notes"), "file": .string(".env")], timeout: 5, maxCharacters: 10_000)
        #expect(hidden.callStatus == .toolError && !hidden.text.contains("secret"))
        let unknown = await runner.call(tool, arguments: ["name": .string("nope")], timeout: 5, maxCharacters: 10_000)
        #expect(unknown.callStatus == .toolError && unknown.text.contains("release-notes"))
    }

    @Test func aLinkOutOfTheSkillIsRefused() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try writeSkill(root, folder: "s", manifest: manifest("s", "S."))
        try "outside".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("out.txt").path,
                                                   withDestinationPath: root.appendingPathComponent("outside.txt").path)
        let settings = BuiltInToolSettings(skills: [summary(dir, "s")])
        let runner = BuiltInToolRunner(settings: { settings })
        let result = await runner.call(BuiltInTools.skillDefinition(settings.skills),
                                       arguments: ["name": .string("s"), "file": .string("out.txt")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .toolError && !result.text.contains("outside\n") && result.text.contains("leads outside"))
    }

    @Test func skillsSwitchedOffSinceTheReplyBeganRunNothing() async throws {
        let runner = BuiltInToolRunner(settings: { BuiltInToolSettings() })
        let tool = BuiltInTools.skillDefinition([SkillSummary(name: "a", description: "d", directoryPath: "/x")])
        let result = await runner.call(tool, arguments: ["name": .string("a")], timeout: 5, maxCharacters: 1000)
        #expect(result.callStatus == .notCalled && result.text == ToolResultText.turnedOff)
    }

    @Test func oneSkillSwitchedOffSinceTheReplyBeganIsTurnedOffNotUnknown() async throws {
        let offered = [SkillSummary(name: "a", description: "d", directoryPath: "/x/a"),
                       SkillSummary(name: "b", description: "d", directoryPath: "/x/b")]
        let runner = BuiltInToolRunner(settings: { BuiltInToolSettings(skills: [offered[1]]) })
        let tool = BuiltInTools.skillDefinition(offered)
        let off = await runner.call(tool, arguments: ["name": .string("a")], timeout: 5, maxCharacters: 1000)
        #expect(off.callStatus == .notCalled && off.text == ToolResultText.turnedOff)
        let never = await runner.call(tool, arguments: ["name": .string("zzz")], timeout: 5, maxCharacters: 1000)
        #expect(never.callStatus == .toolError && never.text.contains("b"))
    }

    @Test func theCardSaysWhichSkillAndFile() {
        #expect(BuiltInTools.approvalDetail(toolName: "activate_skill", arguments: ["name": .string("x")], folderPath: nil)
            == "Built-in tool, loads the skill x")
        #expect(BuiltInTools.approvalDetail(toolName: "activate_skill", arguments: ["name": .string("x"), "file": .string("a.md")], folderPath: nil)
            == "Built-in tool, reads a.md from the skill x")
    }

    @Test func theResultWrapsAndEscapesTheName() {
        let text = BuiltInToolRunner.skillText(name: "a\"<b", body: "B", resources: [], more: false)
        #expect(text.hasPrefix("<skill_content name=\"a&quot;&lt;b\">\nB\n"))
        #expect(text.hasSuffix("</skill_content>"))
    }
}
