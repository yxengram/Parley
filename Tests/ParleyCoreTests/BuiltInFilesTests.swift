import Darwin
import Foundation
import Testing
@testable import ParleyCore

// Real temporary directories. The system's temporary directory is itself reached through a symlink
// (/var is /private/var), so every test here already has a root whose path is not its real path.

private let idle = BuiltInCancelFlag()

/// What Finder hides with: the flag `ls -lO` shows as `hidden`, on a name with no dot.
private func hide(_ url: URL) throws {
    var info = stat()
    #expect(lstat(url.path, &info) == 0)
    let done = chflags(url.path, info.st_flags | UInt32(UF_HIDDEN))
    try #require(done == 0, "chflags failed: \(errno)")
}

private final class SharedFolder {
    let scratch: MCPScratch
    /// The folder a user would pick.
    let root: URL

    init(_ name: String = "Shared") throws {
        scratch = try MCPScratch()
        root = scratch.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var files: BuiltInFiles { BuiltInFiles(rootPath: root.path) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        try write(path, data: Data(text.utf8))
    }

    @discardableResult
    func write(_ path: String, data: Data) throws -> URL {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(path).path, withDestinationPath: target)
    }

    func read(_ path: String, startLine: Int = 1, max: Int = 32000) throws -> String {
        try files.read(path: path, startLine: startLine, maxCharacters: max, cancel: idle)
    }

    func list(_ path: String? = nil) throws -> String {
        try files.list(path: path, cancel: idle)
    }

    /// The message of the refusal `body` must end in.
    func refusal(_ body: () throws -> String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        do {
            let text = try body()
            Issue.record("expected a refusal, got: \(text.prefix(200))", sourceLocation: sourceLocation)
            return ""
        } catch let refusal as BuiltInRefusal {
            return refusal.message
        } catch {
            Issue.record("expected a refusal, got \(error)", sourceLocation: sourceLocation)
            return ""
        }
    }
}

@Suite struct BuiltInPathRuleTests {
    @Test(arguments: ["/etc/passwd", "/", "~", "~/x", "~root/x", "../x", "a/../b", "a/..", "..", ".hidden", "a/.hidden/b", "a/.git", "..a", "a\0b"])
    func refusedWithoutTouchingTheDisk(_ path: String) {
        #expect(throws: BuiltInRefusal.self) { try BuiltInFiles.components(of: path) }
    }

    @Test func dotsAndSlashesThatMeanNothingGo() throws {
        #expect(try BuiltInFiles.components(of: ".") == [])
        #expect(try BuiltInFiles.components(of: "") == [])
        #expect(try BuiltInFiles.components(of: "./a//b/./c/") == ["a", "b", "c"])
        #expect(try BuiltInFiles.components(of: "a.b/c..d") == ["a.b", "c..d"])
    }

    @Test func aSiblingWithTheSamePrefixIsOutside() {
        #expect(BuiltInFiles.relativePart(of: "/foo", root: "/foo") == "")
        #expect(BuiltInFiles.relativePart(of: "/foo/a", root: "/foo") == "a")
        #expect(BuiltInFiles.relativePart(of: "/foobar", root: "/foo") == nil)
        #expect(BuiltInFiles.relativePart(of: "/foobar/a", root: "/foo") == nil)
        #expect(BuiltInFiles.relativePart(of: "/fo", root: "/foo") == nil)
        #expect(BuiltInFiles.relativePart(of: "/etc/x", root: "/") == "etc/x")
    }
}

@Suite struct BuiltInListFilesTests {
    @Test func aFolderIsListedSortedWithHiddenEntriesLeftOut() throws {
        let folder = try SharedFolder()
        try folder.write("b.txt", "12345")
        try folder.write("a/inner.txt", "x")
        try folder.write(".env", "SECRET=1")
        try folder.write(".git/config", "x")
        try folder.link("link", to: "b.txt")
        #expect(try folder.list() == "a/\nb.txt (5 bytes)\nlink (symlink)")
        #expect(try folder.list(".") == folder.list())
        #expect(try folder.list("a") == "inner.txt (1 bytes)")
        #expect(try folder.list("./a/") == "inner.txt (1 bytes)")
    }

    @Test func aFIFOShowsAsSomethingElse() throws {
        let folder = try SharedFolder()
        #expect(mkfifo(folder.url("pipe").path, 0o600) == 0)
        #expect(try folder.list() == "pipe (not a regular file)")
    }

    @Test func emptyMeansEmptyEvenWithHiddenFiles() throws {
        let folder = try SharedFolder()
        #expect(try folder.list() == "The folder is empty.")
        try folder.write(".hidden", "x")
        #expect(try folder.list() == "The folder is empty.")
    }

    @Test func atMost500Entries() throws {
        let folder = try SharedFolder()
        for index in 0..<503 { try folder.write(String(format: "f%04d", index), "") }
        let lines = try folder.list().components(separatedBy: "\n")
        #expect(lines.count == 501)
        #expect(lines.first == "f0000 (0 bytes)")
        #expect(lines[499] == "f0499 (0 bytes)")
        #expect(lines.last == "[3 more not shown]")
    }

    @Test func aFileIsNotAFolder() throws {
        let folder = try SharedFolder()
        try folder.write("a.txt", "x")
        #expect(folder.refusal { try folder.list("a.txt") }.contains("read_file"))
        #expect(folder.refusal { try folder.list("nope") } == "nope does not exist.")
    }

    @Test func aSymlinkedFolderInsideIsFollowed() throws {
        let folder = try SharedFolder()
        try folder.write("real/a.txt", "x")
        try folder.link("alias", to: "real")
        #expect(try folder.list("alias") == "a.txt (1 bytes)")
    }

    @Test func aLinkOutIsNotListed() throws {
        let folder = try SharedFolder()
        try FileManager.default.createDirectory(at: folder.scratch.url.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try folder.link("out", to: folder.scratch.path("Other"))
        #expect(folder.refusal { try folder.list("out") } == "out leads outside the shared folder.")
    }

    @Test func aLongListingStopsWhenCancelled() throws {
        let folder = try SharedFolder()
        try folder.write("a", "")
        let cancel = BuiltInCancelFlag()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try folder.files.list(path: nil, cancel: cancel) }
    }
}

@Suite struct BuiltInReadFileTests {
    @Test func aFileIsReturnedWhole() throws {
        let folder = try SharedFolder()
        try folder.write("a/notes.txt", "one\ntwo\n")
        #expect(try folder.read("a/notes.txt") == "one\ntwo")
        #expect(try folder.read("./a/notes.txt") == "one\ntwo")
    }

    @Test func noTrailingNewlineAndABOMChangeNothing() throws {
        let folder = try SharedFolder()
        try folder.write("a", "\u{FEFF}one\ntwo")
        #expect(try folder.read("a") == "one\ntwo")
    }

    @Test func anEmptyFileIsEmpty() throws {
        let folder = try SharedFolder()
        try folder.write("a", "")
        #expect(try folder.read("a") == "")
    }

    @Test func startLineCountsFromOne() throws {
        let folder = try SharedFolder()
        try folder.write("a", "1\n2\n3\n4\n")
        #expect(try folder.read("a", startLine: 3) == "3\n4\n\n[Lines 3 to 4 of 4.]")
        #expect(try folder.read("a", startLine: 4) == "4\n\n[Lines 4 to 4 of 4.]")
        #expect(folder.refusal { try folder.read("a", startLine: 5) } == "start_line 5 is past the end: the file has 4 lines.")
    }

    @Test func windowsLineEndingsStillSplit() throws {
        let folder = try SharedFolder()
        try folder.write("a", "one\r\ntwo\r\nthree\r\n")
        #expect(try folder.read("a", startLine: 3).hasPrefix("three"))
    }

    @Test func wholeLinesFitTheBudgetAndTheFooterSaysHowToGoOn() throws {
        let folder = try SharedFolder()
        let lines = (1...100).map { String(format: "line %03d", $0) }
        try folder.write("a", lines.joined(separator: "\n"))
        // 120 for the footer, leaving room for 9 lines of 8 characters and a newline each.
        let page = try folder.read("a", max: 120 + 9 * 9)
        #expect(page == lines.prefix(9).joined(separator: "\n") + "\n\n[Lines 1 to 9 of 100. Call again with start_line=10 for more.]")
        #expect(page.count <= 120 + 9 * 9)
        let next = try folder.read("a", startLine: 10, max: 120 + 9 * 9)
        #expect(next.hasPrefix("line 010\n"))
        #expect(next.hasSuffix("[Lines 10 to 18 of 100. Call again with start_line=19 for more.]"))
    }

    @Test func aLineOverTheBudgetIsLeftToProjection() async throws {
        let folder = try SharedFolder()
        try folder.write("a", String(repeating: "x", count: 500) + "\nnext\n")
        let text = try folder.read("a", max: 200)
        #expect(text.hasPrefix(String(repeating: "x", count: 500)))
        #expect(text.hasSuffix("[Lines 1 to 1 of 2. Call again with start_line=2 for more.]"))

        let runner = BuiltInToolRunner(settings: { BuiltInToolSettings(enabled: ["read_file"], folderPath: folder.root.path) })
        let result = await runner.call(BuiltInTools.Tool.readFile.definition, arguments: ["path": .string("a")], timeout: 5, maxCharacters: 200)
        #expect(result.callStatus == .completed)
        #expect(result.originalCharacters != nil)
        #expect(result.text.contains("[Truncated by Parley: showing the first 200 of"))
    }

    @Test func aBinaryFileIsNotText() throws {
        let folder = try SharedFolder()
        try folder.write("nul", data: Data([0x61, 0x00, 0x62]))
        try folder.write("bad", data: Data([0x61, 0xFF, 0xFE]))
        try folder.write("late", data: Data(repeating: 0x61, count: 9000) + Data([0]))
        for name in ["nul", "bad", "late"] {
            #expect(folder.refusal { try folder.read(name) } == "\(name) is not a text file.")
        }
    }

    @Test func exactlyTheCapIsAWholeFile() throws {
        let folder = try SharedFolder()
        let line = String(repeating: "a", count: 1023) + "\n"
        try folder.write("a", String(repeating: line, count: BuiltInFiles.maxReadBytes / 1024))
        let text = try folder.read("a", startLine: 4096, max: 2000)
        #expect(text.hasSuffix("[Lines 4096 to 4096 of 4096.]"))
    }

    @Test func aFileOverTheCapSaysSoAndDoesNotKnowItsLength() throws {
        let folder = try SharedFolder()
        let line = String(repeating: "a", count: 1023) + "\n"
        try folder.write("a", String(repeating: line, count: BuiltInFiles.maxReadBytes / 1024 + 10))
        let first = try folder.read("a", max: 3000)
        #expect(first.hasSuffix("[Lines 1 to 2 of at least 4096. Call again with start_line=3 for more.]"))
        #expect(try folder.read("a", startLine: 4096, max: 2000).hasSuffix("[Lines 4096 to 4096. Parley reads only the first 4 MiB of a file, and this one is longer.]"))
        #expect(folder.refusal { try folder.read("a", startLine: 4097) }.contains("first 4 MiB"))
    }

    @Test(arguments: [1, 2, 3])
    func aCharacterCutAtTheCapIsNotBinary(_ padding: Int) throws {
        let folder = try SharedFolder()
        // Places a four-byte character across the cap, cut after `4 - padding` of its bytes.
        var data = Data(repeating: 0x61, count: BuiltInFiles.maxReadBytes - 4 + padding)
        data.append(contentsOf: Array("😀".utf8))
        data.append(contentsOf: Array("😀".utf8))
        try folder.write("a", data: data)
        let text = try folder.read("a")
        #expect(text.hasPrefix("aaa"))
        #expect(text.hasSuffix("first 4 MiB of a file, and this one is longer.]"))
    }

    @Test func aFolderIsNotAFile() throws {
        let folder = try SharedFolder()
        try folder.write("a/b", "x")
        #expect(folder.refusal { try folder.read("a") }.contains("list_files"))
        #expect(folder.refusal { try folder.read(".") }.contains("list_files"))
    }

    @Test func aFIFOIsRefusedAtOnceAndNeverHangs() throws {
        let folder = try SharedFolder()
        #expect(mkfifo(folder.url("pipe").path, 0o600) == 0)
        #expect(folder.refusal { try folder.read("pipe") } == "pipe is not a regular file.")
    }

    @Test func aDeviceThroughASymlinkIsOutside() throws {
        let folder = try SharedFolder()
        try folder.link("zero", to: "/dev/zero")
        #expect(folder.refusal { try folder.read("zero") } == "zero leads outside the shared folder.")
    }

    @Test func aMissingFile() throws {
        let folder = try SharedFolder()
        #expect(folder.refusal { try folder.read("nope") } == "nope does not exist.")
        try folder.write("file", "x")
        #expect(folder.refusal { try folder.read("file/below") } == "file/below does not exist.")
    }

    @Test func aFolderThatWentIsSaidWithoutItsPath() throws {
        let folder = try SharedFolder()
        try FileManager.default.removeItem(at: folder.root)
        #expect(folder.refusal { try folder.read("a") } == "The shared folder is not available. The user can choose it again in Settings > Built-in Tools.")
        #expect(folder.refusal { try folder.list() }.hasPrefix("The shared folder is not available."))
    }

    @Test func aReadStopsWhenCancelled() throws {
        let folder = try SharedFolder()
        try folder.write("a", "x")
        let cancel = BuiltInCancelFlag()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try folder.files.read(path: "a", startLine: 1, maxCharacters: 100, cancel: cancel) }
    }
}

@Suite struct BuiltInContainmentTests {
    @Test func aSymlinkOutIsRefused() throws {
        let folder = try SharedFolder()
        let secret = folder.scratch.url.appendingPathComponent("secret.txt")
        try Data("outside".utf8).write(to: secret)
        try folder.link("out", to: secret.path)
        try folder.link("relative", to: "../secret.txt")
        #expect(folder.refusal { try folder.read("out") } == "out leads outside the shared folder.")
        #expect(folder.refusal { try folder.read("relative") } == "relative leads outside the shared folder.")
    }

    @Test func aSymlinkedFolderCannotBeWalkedOutThrough() throws {
        let folder = try SharedFolder()
        let other = folder.scratch.url.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: other.appendingPathComponent("secret.txt"))
        try folder.link("door", to: other.path)
        #expect(folder.refusal { try folder.read("door/secret.txt") } == "door/secret.txt leads outside the shared folder.")
    }

    @Test func aSiblingFolderWithTheSamePrefixIsOutside() throws {
        let folder = try SharedFolder("foo")
        let sibling = folder.scratch.url.appendingPathComponent("foobar")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: sibling.appendingPathComponent("secret.txt"))
        try folder.link("next", to: "../foobar/secret.txt")
        #expect(folder.refusal { try folder.read("next") } == "next leads outside the shared folder.")
        #expect(folder.refusal { try folder.list("next") } == "next leads outside the shared folder.")
    }

    /// As ~/Library is hidden: by the flag, not the name.
    @Test func finderHiddenItemsAreNotListed() throws {
        let folder = try SharedFolder()
        try folder.write("plain.txt", "x")
        try hide(try folder.write("flagged.txt", "secret"))
        try folder.write("Library/a.txt", "secret")
        try hide(folder.url("Library"))
        #expect(try folder.list() == "plain.txt (1 bytes)")
    }

    @Test func aFolderOfOnlyFinderHiddenItemsIsEmpty() throws {
        let folder = try SharedFolder()
        try hide(try folder.write("flagged.txt", "secret"))
        #expect(try folder.list() == "The folder is empty.")
    }

    @Test func finderHiddenItemsCannotBeReached() throws {
        let folder = try SharedFolder()
        try hide(try folder.write("flagged.txt", "secret"))
        try folder.write("Library/Deep/a.txt", "secret")
        try hide(folder.url("Library"))
        #expect(folder.refusal { try folder.read("flagged.txt") }.contains("hidden"))
        #expect(folder.refusal { try folder.read("Library/a.txt") }.contains("does not exist"))
        #expect(folder.refusal { try folder.read("Library/Deep/a.txt") }.contains("hidden"))
        #expect(folder.refusal { try folder.list("Library") }.contains("hidden"))
        #expect(folder.refusal { try folder.list("Library/Deep") }.contains("hidden"))
    }

    @Test func aLinkDoesNotGetPastTheFlag() throws {
        let folder = try SharedFolder()
        try hide(try folder.write("flagged.txt", "secret"))
        try folder.link("open.txt", to: "flagged.txt")
        #expect(folder.refusal { try folder.read("open.txt") }.contains("hidden"))
    }

    /// A folder chosen on purpose is the user's, ~/Library for one, and so is one inside a hidden one.
    @Test func aChosenFolderMayBeFinderHidden() throws {
        let scratch = try MCPScratch()
        let outer = scratch.url.appendingPathComponent("Library")
        let chosen = outer.appendingPathComponent("Chosen")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: chosen.appendingPathComponent("a.txt"))
        try hide(outer)
        try hide(chosen)
        let files = BuiltInFiles(rootPath: chosen.path)
        #expect(try files.read(path: "a.txt", startLine: 1, maxCharacters: 100, cancel: idle) == "text")
        #expect(try files.list(path: nil, cancel: idle) == "a.txt (4 bytes)")
    }

    // A combining mark or a Prepend character joins a neighbouring "." or "/" into one Character, so
    // these names look harmless to anything that works on Characters. The kernel works on bytes.

    @Test func aDotWithACombiningMarkIsStillADot() throws {
        let folder = try SharedFolder()
        try folder.write("plain.txt", "x")
        try folder.write(".\u{301}env", "secret")
        #expect(try folder.list() == "plain.txt (1 bytes)")
        #expect(folder.refusal { try folder.read(".\u{301}env") }.contains("Hidden"))
    }

    @Test func aPrependCharacterDoesNotHideASlash() throws {
        let folder = try SharedFolder()
        try folder.write("x\u{600}/.env", "secret")
        try folder.write("x\u{600}/.git/config", "secret")
        try folder.write("x\u{600}/fine.txt", "fine")
        #expect(folder.refusal { try folder.read("x\u{600}/.env") }.contains("Hidden"))
        #expect(folder.refusal { try folder.read("x\u{600}/.git/config") }.contains("Hidden"))
        #expect(try folder.read("x\u{600}/fine.txt") == "fine")
    }

    @Test func aPathTakenApartByByte() throws {
        #expect(try BuiltInFiles.components(of: "x\u{600}/y") == ["x\u{600}", "y"])
        #expect(throws: BuiltInRefusal.self) { try BuiltInFiles.components(of: "x\u{600}/..") }
        #expect(throws: BuiltInRefusal.self) { try BuiltInFiles.components(of: "/\u{301}etc/hosts") }
        #expect(throws: BuiltInRefusal.self) { try BuiltInFiles.components(of: "~\u{301}/x") }
    }

    /// Reached through a link, so that the hidden name is seen only in the real path.
    @Test func aLinkToADotNameWithAMarkIsRefused() throws {
        let folder = try SharedFolder()
        try folder.write(".\u{301}env", "secret")
        try folder.link("open.txt", to: ".\u{301}env")
        #expect(folder.refusal { try folder.read("open.txt") }.contains("hidden"))
    }

    @Test func aNameStartingWithACombiningMarkIsInside() throws {
        let folder = try SharedFolder()
        try folder.write("\u{301}lead.txt", "fine")
        #expect(try folder.read("\u{301}lead.txt") == "fine")
        #expect(BuiltInFiles.relativePart(of: "/r/\u{301}a", root: "/r") == "\u{301}a")
    }

    /// Equal as Swift Strings, but two paths to the kernel.
    @Test func theRootIsComparedByByte() {
        #expect(BuiltInFiles.relativePart(of: "/caf\u{E9}/a", root: "/cafe\u{301}") == nil)
        #expect(BuiltInFiles.relativePart(of: "/caf\u{E9}", root: "/cafe\u{301}") == nil)
        #expect(BuiltInFiles.relativePart(of: "/foobar", root: "/foo") == nil)
        #expect(BuiltInFiles.relativePart(of: "/foo", root: "/foo") == "")
        #expect(BuiltInFiles.relativePart(of: "/foo/a", root: "/") == "foo/a")
    }

    @Test func aSymlinkToSomethingHiddenIsRefused() throws {
        let folder = try SharedFolder()
        try folder.write(".env", "SECRET=1")
        try folder.write(".git/config", "x")
        try folder.link("env", to: ".env")
        try folder.link("gitdir", to: ".git")
        #expect(folder.refusal { try folder.read("env") }.contains("hidden"))
        #expect(folder.refusal { try folder.list("gitdir") }.contains("hidden"))
        #expect(folder.refusal { try folder.read("gitdir/config") }.contains("hidden"))
    }

    @Test func aSymlinkInsideIsFollowed() throws {
        let folder = try SharedFolder()
        try folder.write("real.txt", "inside")
        try folder.link("alias", to: "real.txt")
        #expect(try folder.read("alias") == "inside")
    }

    @Test func aRootReachedThroughASymlinkWorks() throws {
        // /tmp is a symlink to /private/tmp.
        let name = "parley-builtin-" + UUID().uuidString
        let root = "/tmp/" + name
        #expect(mkdir(root, 0o700) == 0)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("through".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))

        let files = BuiltInFiles(rootPath: root)
        #expect(try files.read(path: "a.txt", startLine: 1, maxCharacters: 100, cancel: idle) == "through")
        #expect(try files.list(path: nil, cancel: idle) == "a.txt (7 bytes)")
    }

    @Test func theRootItselfBeingALinkWorks() throws {
        let folder = try SharedFolder()
        try folder.write("a.txt", "x")
        let alias = folder.scratch.path("Alias")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: folder.root.path)
        #expect(try BuiltInFiles(rootPath: alias).list(path: nil, cancel: idle) == "a.txt (1 bytes)")
    }

    @Test func theRootIsTakenFreshOnEveryCall() throws {
        let folder = try SharedFolder()
        let alias = folder.scratch.path("Alias")
        let elsewhere = folder.scratch.url.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("second".utf8).write(to: elsewhere.appendingPathComponent("a.txt"))
        try folder.write("a.txt", "first")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: folder.root.path)
        let files = BuiltInFiles(rootPath: alias)
        #expect(try files.read(path: "a.txt", startLine: 1, maxCharacters: 100, cancel: idle) == "first")
        try FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: elsewhere.path)
        #expect(try files.read(path: "a.txt", startLine: 1, maxCharacters: 100, cancel: idle) == "second")
    }

    /// Everything the model can be told, across every way a call can end.
    @Test func noResultEverHoldsAnAbsolutePathOrTheFoldersName() async throws {
        let folder = try SharedFolder("PrivateFolderName")
        try folder.write("a.txt", "one\ntwo\n")
        try folder.write("sub/b.txt", "x")
        try folder.write("bin", data: Data([0]))
        try folder.link("out", to: "/etc/hosts")
        try folder.link("loop", to: "loop")
        #expect(mkfifo(folder.url("pipe").path, 0o600) == 0)

        var real = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        #expect(realpath(folder.root.path, &real) != nil)
        let forbidden = [folder.root.path, String(cString: real), "PrivateFolderName", NSUserName(), NSHomeDirectory(), "/private", "/var/folders"]

        let settings = BuiltInToolSettings(enabled: ["list_files", "read_file"], folderPath: folder.root.path)
        let runner = BuiltInToolRunner(settings: { settings })
        let reads: [[String: JSONValue]] = [
            ["path": .string("a.txt")], ["path": .string("a.txt"), "start_line": .int(2)], ["path": .string("a.txt"), "start_line": .int(9)],
            ["path": .string("a.txt"), "start_line": .string("x")], ["path": .string("sub")], ["path": .string("bin")], ["path": .string("out")],
            ["path": .string("loop")], ["path": .string("pipe")], ["path": .string("nope")], ["path": .string("/etc/hosts")],
            ["path": .string("../x")], ["path": .string(".hidden")], ["path": .string("~/x")], ["path": .int(1)], [:],
        ]
        let lists: [[String: JSONValue]] = [
            [:], ["path": .string("sub")], ["path": .string("a.txt")], ["path": .string("out")], ["path": .string("nope")], ["path": .int(1)],
        ]
        var results: [ToolCallResult] = []
        for arguments in reads {
            results.append(await runner.call(BuiltInTools.Tool.readFile.definition, arguments: arguments, timeout: 5, maxCharacters: 1000))
        }
        for arguments in lists {
            results.append(await runner.call(BuiltInTools.Tool.listFiles.definition, arguments: arguments, timeout: 5, maxCharacters: 1000))
        }
        try FileManager.default.removeItem(at: folder.root)
        results.append(await runner.call(BuiltInTools.Tool.listFiles.definition, arguments: [:], timeout: 5, maxCharacters: 1000))

        for result in results {
            for text in forbidden {
                #expect(!result.text.contains(text), "\(result.text)")
            }
        }
        #expect(results.contains { $0.callStatus == .completed })
        #expect(results.contains { $0.callStatus == .toolError })
    }
}

@Suite struct BuiltInFileCallTests {
    @Test func aCancelledCallReturnsAtOnce() async throws {
        let folder = try SharedFolder()
        try folder.write("a", "x")
        let settings = BuiltInToolSettings(enabled: ["read_file"], folderPath: folder.root.path)
        let runner = BuiltInToolRunner(settings: { settings })
        let task = Task<ToolCallResult, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runner.call(BuiltInTools.Tool.readFile.definition, arguments: ["path": .string("a")], timeout: 5, maxCharacters: 100)
        }
        #expect(await task.value.callStatus == .notCalled)
    }
}
