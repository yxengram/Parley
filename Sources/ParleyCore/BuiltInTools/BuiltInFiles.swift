import Darwin
import Foundation

/// `list_files`, `read_file` and `write_file`, inside the one folder chosen in Settings.
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
/// Writing never follows a link: see `write`.
///
/// Blocking and meant for a thread of its own (a file on a network mount or in iCloud can take as
/// long as it likes). `cancel` is checked between reads.
struct BuiltInFiles {
    static let maxReadBytes = 4 * 1024 * 1024
    static let maxWriteBytes = 4 * 1024 * 1024
    /// Moves a file to the Trash. A parameter, so no test touches the real one.
    typealias Trasher = @Sendable (URL) throws -> Void
    static let moveToTrash: Trasher = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    static let maxEntries = 500
    /// Room kept for the footer inside the character budget.
    private static let footerRoom = 120
    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")
    /// What the messages call the folder, and how they point at the other tool. They go to the
    /// model, so they hold no path or folder name.
    struct Wording: Sendable {
        /// Starts a sentence: "The shared folder".
        var folder: String
        /// Mid-sentence: "the shared folder".
        var folderInSentence: String
        /// Says where to fix it.
        var unavailable: String
        var listHint: String
        var readHint: String

        static let sharedFolder = Wording(
            folder: "The shared folder", folderInSentence: "the shared folder",
            unavailable: "The shared folder is not available. The user can choose it again in Settings > Built-in Tools.",
            listHint: "Use list_files to see what is in it.", readHint: "Use read_file to read it.")
        static let skillFolder = Wording(
            folder: "The skill's folder", folderInSentence: "the skill's folder",
            unavailable: "The skill's folder is not available any more. The user may have removed the skill in Settings > Skills.",
            listHint: "Ask for a file in it: the skill's files are listed when the skill is loaded.",
            readHint: "Ask for it with the file argument.")
    }

    let rootPath: String
    var wording: Wording = .sharedFolder
    var trash: Trasher = BuiltInFiles.moveToTrash

    // MARK: list_files

    func list(path: String?, cancel: BuiltInCancelFlag) throws -> String {
        let relative = try Self.components(of: path ?? ".", wording: wording)
        let target = try open(relative)
        defer { close(target.fd) }
        guard target.isDirectory else { throw BuiltInRefusal("\(shown(relative)) is a file. \(wording.readHint)") }

        // fdopendir owns what it is given and closes it with the stream.
        let duplicate = dup(target.fd)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw BuiltInRefusal("\(shown(relative)) could not be listed.")
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
        let relative = try Self.components(of: path, wording: wording)
        guard !relative.isEmpty else { throw BuiltInRefusal("\(wording.folder) is a folder. \(wording.listHint)") }
        let target = try open(relative)
        defer { close(target.fd) }
        if target.isDirectory { throw BuiltInRefusal("\(shown(relative)) is a folder. \(wording.listHint)") }
        guard target.isRegular else { throw BuiltInRefusal("\(shown(relative)) is not a regular file.") }

        let (data, wasCut) = try readCapped(target.fd, relative: relative, cancel: cancel)
        guard let text = Self.decoded(data, wasCut: wasCut) else { throw BuiltInRefusal("\(shown(relative)) is not a text file.") }
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
                throw BuiltInRefusal("\(shown(relative)) could not be read.")
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

    // MARK: write_file

    /// Writes `content` as UTF-8 at `path`, creating the folders on the way. A file already there is
    /// replaced, and its old version moved to the Trash first; nothing is written if that fails.
    ///
    /// Never through a link: each folder on the way is opened from the one above it with
    /// `O_NOFOLLOW`, so a symlink, even one that leads back inside, is refused, and the descriptors
    /// held are what the kernel says they are whatever is renamed meanwhile. The text goes to a hidden
    /// temporary file in the target's folder, then `renameatx_np(RENAME_EXCL)` puts it in place, so
    /// a half-written file is never seen under the real name and nothing that appeared there
    /// meanwhile is overwritten. The Trash is given the folder's real path (`F_GETPATH`).
    ///
    /// `cancel` is checked until the file is put in place; after that it is written.
    func write(path: String, content: String, cancel: BuiltInCancelFlag) throws -> String {
        let relative = try Self.components(of: path, wording: wording, action: "written")
        guard let name = relative.last else {
            throw BuiltInRefusal("\(wording.folder) is a folder. Give a file's path, such as notes.txt.")
        }
        let data = Data(content.utf8)
        guard data.count <= Self.maxWriteBytes else {
            throw BuiltInRefusal("The content is \(data.count) bytes. Parley writes at most 4 MiB to one file.")
        }
        let folder = try openFolderForWriting(Array(relative.dropLast()))
        defer { close(folder) }
        if cancel.isSet { throw CancellationError() }

        let shownPath = shown(relative)
        var existing = stat()
        var replacing = false
        var mode: mode_t = 0o644
        if fstatat(folder, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            switch existing.st_mode & S_IFMT {
            case S_IFREG: break
            case S_IFDIR: throw BuiltInRefusal("\(shownPath) is a folder.")
            case S_IFLNK: throw BuiltInRefusal("\(shownPath) is a symlink. Parley does not write through or replace links.")
            default: throw BuiltInRefusal("\(shownPath) is not a regular file.")
            }
            if Self.isFlaggedHidden(existing) { throw BuiltInRefusal("\(shownPath) is hidden, so it cannot be written.") }
            replacing = true
            mode = existing.st_mode & 0o777
        } else if errno != ENOENT {
            throw Self.writeRefusal(errno, shownPath)
        }

        let temporary = ".parley-write-\(UUID().uuidString)"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Self.writeRefusal(errno, shownPath) }
        var placed = false
        defer { if !placed { unlinkat(folder, temporary, 0) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    if cancel.isSet { throw CancellationError() }
                    let count = Darwin.write(fd, raw.baseAddress! + written, min(1 << 20, raw.count - written))
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw Self.writeRefusal(errno, shownPath)
                    }
                    written += count
                }
            }
            guard fsync(fd) == 0 else { throw Self.writeRefusal(errno, shownPath) }
        }
        if cancel.isSet { throw CancellationError() }

        if replacing {
            // Still the file that was looked at: not swapped for a link or another file meanwhile.
            var now = stat()
            guard fstatat(folder, name, &now, AT_SYMLINK_NOFOLLOW) == 0, now.st_mode & S_IFMT == S_IFREG,
                  now.st_ino == existing.st_ino, now.st_dev == existing.st_dev, let real = Self.realPath(folder) else {
                throw BuiltInRefusal("\(shownPath) changed while it was being written. Nothing was written.")
            }
            do {
                try trash(URL(fileURLWithPath: real, isDirectory: true).appendingPathComponent(name))
            } catch {
                throw BuiltInRefusal("\(shownPath) exists, and its old version could not be moved to the Trash, so nothing was written.")
            }
        }
        guard Self.renameIntoPlace(folder, temporary, name) == 0 else {
            let failure = errno
            if replacing {
                throw BuiltInRefusal("The old version of \(shownPath) was moved to the Trash, but the new one could not be put in its place.")
            }
            if failure == EEXIST { throw BuiltInRefusal("\(shownPath) appeared while it was being written. Nothing was written.") }
            throw Self.writeRefusal(failure, shownPath)
        }
        placed = true
        let size = data.count == 1 ? "1 byte" : "\(data.count) bytes"
        return replacing
            ? "Wrote \(shownPath) (\(size)). The old version was moved to the Trash."
            : "Created \(shownPath) (\(size))."
    }

    /// `renameatx_np(RENAME_EXCL)`. A volume that does not have it (some network or FAT volumes
    /// answer ENOTSUP or EINVAL) gets a plain rename, after a check that the name is still free.
    private static func renameIntoPlace(_ folder: Int32, _ temporary: String, _ name: String) -> Int32 {
        if renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL)) == 0 { return 0 }
        guard errno == ENOTSUP || errno == EINVAL else { return -1 }
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            errno = EEXIST
            return -1
        }
        return renameat(folder, temporary, folder, name)
    }

    /// The folder `relative` names, made where missing, as a descriptor the caller closes. Every step
    /// is opened from the one before with `O_NOFOLLOW`; the chosen folder itself may be reached
    /// through a link, as it is for reading.
    private func openFolderForWriting(_ relative: [String]) throws -> Int32 {
        var current = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw BuiltInRefusal(wording.unavailable) }
        var walked: [String] = []
        for part in relative {
            walked.append(part)
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var next = openat(current, part, flags)
            if next < 0, errno == ENOENT {
                if mkdirat(current, part, 0o755) != 0, errno != EEXIST {
                    let failure = errno
                    close(current)
                    throw Self.writeRefusal(failure, shown(walked))
                }
                next = openat(current, part, flags)
            }
            guard next >= 0 else {
                let failure = errno
                // A link fails as "not a folder" (or ELOOP): which it was, from the entry itself.
                var entry = stat()
                let isLink = fstatat(current, part, &entry, AT_SYMLINK_NOFOLLOW) == 0 && entry.st_mode & S_IFMT == S_IFLNK
                close(current)
                if isLink || failure == ELOOP { throw BuiltInRefusal("\(shown(walked)) is a symlink. Parley does not write through links.") }
                if failure == ENOTDIR { throw BuiltInRefusal("\(shown(walked)) is a file, not a folder.") }
                throw Self.writeRefusal(failure, shown(walked))
            }
            close(current)
            current = next
            var info = stat()
            guard fstat(current, &info) == 0, !Self.isFlaggedHidden(info) else {
                close(current)
                throw BuiltInRefusal("\(shown(walked)) is hidden, so nothing can be written in it.")
            }
        }
        return current
    }

    private static func writeRefusal(_ code: Int32, _ name: String) -> BuiltInRefusal {
        switch code {
        case EACCES, EPERM: return BuiltInRefusal("macOS refused to write \(name).")
        case EROFS: return BuiltInRefusal("\(name) is on a disk that cannot be written to.")
        case ENOSPC, EDQUOT: return BuiltInRefusal("There is not enough disk space to write \(name).")
        case ENAMETOOLONG: return BuiltInRefusal("The name \(name) is too long.")
        default: return BuiltInRefusal("\(name) could not be written.")
        }
    }

    // MARK: Staying inside

    /// The path's parts, for the checks that need no disk. "." and empty parts mean nothing, so
    /// "./a/" is "a" and "." is the folder itself.
    static func components(of path: String, wording: Wording = .sharedFolder, action: String = "read") throws -> [String] {
        if path.unicodeScalars.contains("\0") { throw BuiltInRefusal("The path holds a NUL character.") }
        if path.utf8.first == slash || path.utf8.first == UInt8(ascii: "~") {
            throw BuiltInRefusal("Paths are relative to \(wording.folderInSentence), which is \".\". Absolute paths and ~ are refused.")
        }
        let parts = path.utf8.split(separator: slash).map { String(Substring($0)) }.filter { $0 != "." }
        if parts.contains("..") { throw BuiltInRefusal("\"..\" is refused: nothing outside \(wording.folderInSentence) can be reached.") }
        if parts.contains(where: { $0.utf8.first == dot }) { throw BuiltInRefusal("Hidden files and folders cannot be \(action).") }
        return parts
    }

    private func shown(_ relative: [String]) -> String {
        relative.isEmpty ? wording.folder : relative.joined(separator: "/")
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
        guard root >= 0 else { throw BuiltInRefusal(wording.unavailable) }
        defer { close(root) }
        guard let rootReal = Self.realPath(root) else { throw BuiltInRefusal(wording.unavailable) }

        let fd = relative.isEmpty ? dup(root) : openat(root, relative.joined(separator: "/"), flags)
        guard fd >= 0 else {
            let name = shown(relative)
            switch errno {
            case ENOENT, ENOTDIR: throw BuiltInRefusal("\(name) does not exist.")
            case EACCES, EPERM: throw BuiltInRefusal("macOS refused access to \(name).")
            default: throw BuiltInRefusal("\(name) could not be opened.")
            }
        }
        var keep = false
        defer { if !keep { close(fd) } }

        guard let real = Self.realPath(fd), let inside = Self.relativePart(of: real, root: rootReal) else {
            throw BuiltInRefusal("\(shown(relative)) leads outside \(wording.folderInSentence).")
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw BuiltInRefusal("\(shown(relative)) could not be opened.") }
        // The descriptor's own flag cannot be swapped under the check; the folders above it go by path.
        if (!inside.isEmpty && Self.isFlaggedHidden(info)) || Self.isHidden(inside, below: root) {
            throw BuiltInRefusal("\(shown(relative)) leads to a hidden file or folder, which cannot be read.")
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
