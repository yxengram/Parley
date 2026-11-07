import Darwin
import Foundation

/// `list_files` and `read_file`, inside the one folder chosen in Settings.
///
/// What the model sees is relative to that folder, always: no absolute path, user name or folder name
/// in a result or an error. Each call opens the folder anew and asks the kernel where a descriptor
/// really is, so a symlink can point anywhere and an answer still comes only from inside. All reads
/// go through that one descriptor, so swapping a symlink after the check changes nothing.
///
/// Known limit: a hard link to a file outside the folder cannot be told apart from a file inside.
///
/// Paths are taken apart by byte, as the kernel does. Swift's characters would not do: a combining mark
/// after "." or "/" joins it into one character, and the check would see a name the kernel does not.
///
/// Hidden means what the user means by it: a name starting with a dot, or Finder's hidden flag, which
/// is how ~/Library is hidden. A folder the user chose is theirs, so only what is below it counts.
///
/// Blocking and meant for a thread of its own (a file on a network mount or in iCloud can take as
/// long as it likes). `cancel` is checked between reads.
struct BuiltInFiles {
    static let maxReadBytes = 4 * 1024 * 1024
    static let maxEntries = 500
    /// Room kept for the footer inside the character budget.
    private static let footerRoom = 120
    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")
    /// Says where to fix it, and no path or folder name: this goes to the model.
    private static let folderUnavailable = "The shared folder is not available. The user can choose it again in Settings > Built-in Tools."

    let rootPath: String

    // MARK: list_files

    func list(path: String?, cancel: BuiltInCancelFlag) throws -> String {
        let relative = try Self.components(of: path ?? ".")
        let target = try open(relative)
        defer { close(target.fd) }
        guard target.isDirectory else { throw BuiltInRefusal("\(Self.shown(relative)) is a file. Use read_file to read it.") }

        // fdopendir owns what it is given and closes it with the stream.
        let duplicate = dup(target.fd)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw BuiltInRefusal("\(Self.shown(relative)) could not be listed.")
        }
        defer { closedir(stream) }

        var names: [String] = []
        while let entry = readdir(stream) {
            if cancel.isSet { throw CancellationError() }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name.utf8.first == Self.dot { continue }
            // Here and not below, so the count and the empty-folder text leave these out too.
            var info = stat()
            if fstatat(target.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, Self.isFlaggedHidden(info) { continue }
            names.append(name)
        }
        names.sort()
        if names.isEmpty { return "The folder is empty." }

        var lines: [String] = []
        for name in names.prefix(Self.maxEntries) {
            if cancel.isSet { throw CancellationError() }
            var info = stat()
            guard fstatat(target.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                lines.append(name)
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: lines.append(name + "/")
            case S_IFREG: lines.append("\(name) (\(info.st_size) bytes)")
            // Where it points may be an absolute path, so it is not said.
            case S_IFLNK: lines.append("\(name) (symlink)")
            default: lines.append("\(name) (not a regular file)")
            }
        }
        if names.count > Self.maxEntries { lines.append("[\(names.count - Self.maxEntries) more not shown]") }
        return lines.joined(separator: "\n")
    }

    // MARK: read_file

    func read(path: String, startLine: Int, maxCharacters: Int, cancel: BuiltInCancelFlag) throws -> String {
        let relative = try Self.components(of: path)
        guard !relative.isEmpty else { throw BuiltInRefusal("The shared folder is a folder. Use list_files to see what is in it.") }
        let target = try open(relative)
        defer { close(target.fd) }
        if target.isDirectory { throw BuiltInRefusal("\(Self.shown(relative)) is a folder. Use list_files to see what is in it.") }
        guard target.isRegular else { throw BuiltInRefusal("\(Self.shown(relative)) is not a regular file.") }

        let (data, wasCut) = try readCapped(target.fd, relative: relative, cancel: cancel)
        guard let text = Self.decoded(data, wasCut: wasCut) else { throw BuiltInRefusal("\(Self.shown(relative)) is not a text file.") }
        return try Self.page(of: text, startLine: startLine, maxCharacters: maxCharacters, wasCut: wasCut)
    }

    private func readCapped(_ fd: Int32, relative: [String], cancel: BuiltInCancelFlag) throws -> (data: Data, wasCut: Bool) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < Self.maxReadBytes {
            if cancel.isSet { throw CancellationError() }
            let wanted = min(buffer.count, Self.maxReadBytes - data.count)
            let count = Darwin.read(fd, &buffer, wanted)
            if count < 0 {
                if errno == EINTR { continue }
                throw BuiltInRefusal("\(Self.shown(relative)) could not be read.")
            }
            if count == 0 { return (data, false) }
            data.append(buffer, count: count)
        }
        // Exactly at the cap: one more byte tells a whole file from a cut one.
        var next: UInt8 = 0
        return (data, Darwin.read(fd, &next, 1) == 1)
    }

    /// A character cut at the cap is not invalid text, so up to three bytes may go.
    private static func decoded(_ data: Data, wasCut: Bool) -> String? {
        for cut in 0...(wasCut ? 3 : 0) where data.count >= cut {
            if let text = AttachmentLoader.decodeText(data.dropLast(cut)) { return text }
        }
        return nil
    }

    private static func page(of text: String, startLine: Int, maxCharacters: Int, wasCut: Bool) throws -> String {
        // By byte: "\r\n" is one Character, and splitting on Characters would keep such a file whole.
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let total = lines.count
        guard total > 0 else { return "" }
        let ofTotal = wasCut ? "at least \(total)" : "\(total)"
        guard startLine <= total else {
            let more = wasCut ? " Parley reads only the first 4 MiB of a file." : ""
            throw BuiltInRefusal("start_line \(startLine) is past the end: the file has \(ofTotal) lines.\(more)")
        }

        let budget = max(0, maxCharacters - footerRoom)
        var kept: [String] = []
        var used = 0
        for line in lines[(startLine - 1)...] {
            let text = String(Substring(line))
            let count = text.count + 1
            // The first line goes in whatever its size: projection cuts it and says so.
            if !kept.isEmpty, used + count > budget { break }
            kept.append(text)
            used += count
        }
        var out = kept.joined(separator: "\n")
        let last = startLine + kept.count - 1
        if last < total {
            out += "\n\n[Lines \(startLine) to \(last) of \(ofTotal). Call again with start_line=\(last + 1) for more.]"
        } else if wasCut {
            out += "\n\n[Lines \(startLine) to \(last). Parley reads only the first 4 MiB of a file, and this one is longer.]"
        } else if startLine > 1 {
            out += "\n\n[Lines \(startLine) to \(last) of \(total).]"
        }
        return out
    }

    // MARK: Staying inside

    /// The path's parts, for the checks that need no disk. "." and empty parts mean nothing, so
    /// "./a/" is "a" and "." is the folder itself.
    static func components(of path: String) throws -> [String] {
        if path.unicodeScalars.contains("\0") { throw BuiltInRefusal("The path holds a NUL character.") }
        if path.utf8.first == slash || path.utf8.first == UInt8(ascii: "~") {
            throw BuiltInRefusal("Paths are relative to the shared folder, which is \".\". Absolute paths and ~ are refused.")
        }
        let parts = path.utf8.split(separator: slash).map { String(Substring($0)) }.filter { $0 != "." }
        if parts.contains("..") { throw BuiltInRefusal("\"..\" is refused: nothing outside the shared folder can be reached.") }
        if parts.contains(where: { $0.utf8.first == dot }) { throw BuiltInRefusal("Hidden files and folders cannot be read.") }
        return parts
    }

    private static func shown(_ relative: [String]) -> String {
        relative.isEmpty ? "The shared folder" : relative.joined(separator: "/")
    }

    private struct Target {
        var fd: Int32
        var isDirectory: Bool
        var isRegular: Bool
    }

    /// `O_NONBLOCK`, so a FIFO cannot hang the open. Follows symlinks on purpose: where they lead is
    /// what is checked, by asking the kernel about the descriptor they led to. The caller closes it.
    private func open(_ relative: [String]) throws -> Target {
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
        let root = Darwin.open(rootPath, flags | O_DIRECTORY)
        guard root >= 0 else { throw BuiltInRefusal(Self.folderUnavailable) }
        defer { close(root) }
        guard let rootReal = Self.realPath(root) else { throw BuiltInRefusal(Self.folderUnavailable) }

        let fd = relative.isEmpty ? dup(root) : openat(root, relative.joined(separator: "/"), flags)
        guard fd >= 0 else {
            let shown = Self.shown(relative)
            switch errno {
            case ENOENT, ENOTDIR: throw BuiltInRefusal("\(shown) does not exist.")
            case EACCES, EPERM: throw BuiltInRefusal("macOS refused access to \(shown).")
            default: throw BuiltInRefusal("\(shown) could not be opened.")
            }
        }
        var keep = false
        defer { if !keep { close(fd) } }

        guard let real = Self.realPath(fd), let inside = Self.relativePart(of: real, root: rootReal) else {
            throw BuiltInRefusal("\(Self.shown(relative)) leads outside the shared folder.")
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw BuiltInRefusal("\(Self.shown(relative)) could not be opened.") }
        // The descriptor's own flag cannot be swapped under the check; the folders above it go by path.
        if (!inside.isEmpty && Self.isFlaggedHidden(info)) || Self.isHidden(inside, below: root) {
            throw BuiltInRefusal("\(Self.shown(relative)) leads to a hidden file or folder, which cannot be read.")
        }
        keep = true
        return Target(fd: fd, isDirectory: info.st_mode & S_IFMT == S_IFDIR, isRegular: info.st_mode & S_IFMT == S_IFREG)
    }

    private static func isFlaggedHidden(_ info: stat) -> Bool {
        info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    /// Whether a step of `inside`, a real path below the descriptor `root`, is hidden. A step that
    /// cannot be looked at counts as hidden. Staying inside does not rest on this walk.
    private static func isHidden(_ inside: String, below root: Int32) -> Bool {
        var walked = ""
        for part in inside.utf8.split(separator: slash) {
            if part.first == dot { return true }
            walked += (walked.isEmpty ? "" : "/") + String(Substring(part))
            var info = stat()
            guard fstatat(root, walked, &info, AT_SYMLINK_NOFOLLOW) == 0, !isFlaggedHidden(info) else { return true }
        }
        return false
    }

    /// What the path is below `root`, "" for the root itself, nil outside it. With the slash, so
    /// /foobar is not inside /foo. By byte: a name starting with a combining mark joins the slash
    /// before it into one character, and that file would not count as inside.
    static func relativePart(of real: String, root: String) -> String? {
        if real.utf8.elementsEqual(root.utf8) { return "" }
        let prefix = root.utf8.last == slash ? root : root + "/"
        return real.utf8.starts(with: prefix.utf8) ? String(Substring(real.utf8.dropFirst(prefix.utf8.count))) : nil
    }

    private static func realPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }
}
