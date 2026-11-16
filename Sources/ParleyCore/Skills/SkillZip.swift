import Compression
import Darwin
import Foundation

/// Reads a skill packaged as a zip (`.zip` or `.skill`). Written here rather than handed to a tool,
/// so every entry is checked before a byte of it is written:
/// - only stored and deflated entries, no encryption, no zip64, no multi-disk archives;
/// - a name may not be absolute or a drive path, and may not have a ".." part (zip slip); backslashes
///   count as separators;
/// - symbolic links, hidden names (".git", ".DS_Store") and Finder's "__MACOSX" are skipped;
/// - the number of entries, each file's size and the total are capped, by what the archive says and
///   by what inflating actually gives, and every file's CRC-32 must match;
/// - files are created with O_EXCL | O_NOFOLLOW inside an empty folder of Parley's own.
enum SkillZip {
    static let maxArchiveBytes = 200 * 1024 * 1024

    struct Entry: Equatable {
        var path: [String]
        var isDirectory: Bool
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        return head == Data([0x50, 0x4B, 0x03, 0x04]) || head == Data([0x50, 0x4B, 0x05, 0x06])
    }

    /// Writes the archive's files and folders into `destination`, which must be an empty folder.
    static func extract(_ archive: URL, into destination: URL, limits: SkillImportLimits) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maxArchiveBytes else { throw SkillImportError.tooLarge }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try entries(of: data)
        guard entries.count <= limits.maxEntries * 2 else { throw SkillImportError.tooManyFiles }
        var files = 0
        var total = 0
        for entry in entries where !entry.isDirectory {
            files += 1
            total += entry.size
            guard files <= limits.maxEntries else { throw SkillImportError.tooManyFiles }
            guard entry.size <= limits.maxTotalBytes, total <= limits.maxTotalBytes else { throw SkillImportError.tooLarge }
            guard entry.path.count <= limits.maxDepth else { throw SkillImportError.tooDeep }
        }
        for entry in entries {
            if entry.isDirectory {
                try makeDirectories(entry.path, in: destination)
                continue
            }
            try makeDirectories(Array(entry.path.dropLast()), in: destination)
            let bytes = try contents(of: entry, in: data)
            try write(bytes, to: entry.path, in: destination)
        }
    }

    // MARK: Reading the directory

    static func entries(of data: Data) throws -> [Entry] {
        guard let end = endOfCentralDirectory(in: data) else { throw SkillImportError.notAZip }
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0 else { throw SkillImportError.unsupportedZip }
        let count = Int(data.u16(end + 10))
        let directorySize = Int(data.u32(end + 12))
        let directoryOffset = Int(data.u32(end + 16))
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw SkillImportError.unsupportedZip
        }
        guard directoryOffset + directorySize <= data.count else { throw SkillImportError.notAZip }

        var entries: [Entry] = []
        var at = directoryOffset
        for _ in 0..<count {
            guard at + 46 <= data.count, data.u32(at) == 0x0201_4B50 else { throw SkillImportError.notAZip }
            let madeBy = data.u16(at + 4)
            let flags = data.u16(at + 8)
            let method = data.u16(at + 10)
            let crc = data.u32(at + 16)
            let compressed = Int(data.u32(at + 20))
            let size = Int(data.u32(at + 24))
            let nameLength = Int(data.u16(at + 28))
            let extraLength = Int(data.u16(at + 30))
            let commentLength = Int(data.u16(at + 32))
            let external = data.u32(at + 38)
            let localOffset = Int(data.u32(at + 42))
            let nameStart = at + 46
            guard nameStart + nameLength <= data.count else { throw SkillImportError.notAZip }
            let nameBytes = data.subdata(in: nameStart..<(nameStart + nameLength))
            at = nameStart + nameLength + extraLength + commentLength

            guard flags & 0x1 == 0 else { throw SkillImportError.encryptedZip }
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw SkillImportError.unsupportedZip
            }
            // A Unix symbolic link: its "contents" are where it points. Never followed, never written.
            if madeBy >> 8 == 3, (external >> 16) & UInt32(S_IFMT) == UInt32(S_IFLNK) { continue }

            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            guard let path = try safePath(name) else { continue }
            let isDirectory = name.hasSuffix("/") || name.hasSuffix("\\")
            if path.isEmpty { continue }
            guard isDirectory || method == 0 || method == 8 else { throw SkillImportError.unsupportedZip }
            entries.append(Entry(path: path, isDirectory: isDirectory, method: method, crc: crc,
                                 compressedSize: compressed, size: size, localHeaderOffset: localOffset))
        }
        return entries
    }

    /// The name's parts, nil for an entry that is skipped, or an error for one that tries to leave.
    static func safePath(_ name: String) throws -> [String]? {
        let unified = name.replacingOccurrences(of: "\\", with: "/")
        if unified.unicodeScalars.contains("\0") { throw SkillImportError.unsafeEntry(name) }
        if unified.hasPrefix("/") { throw SkillImportError.unsafeEntry(name) }
        if unified.count >= 2, unified.dropFirst().first == ":", unified.first?.isLetter == true {
            throw SkillImportError.unsafeEntry(name)
        }
        let parts = unified.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        if parts.contains("..") { throw SkillImportError.unsafeEntry(name) }
        if parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) { return nil }
        return parts
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var at = data.count - 22
        while at >= lowest {
            if data.u32(at) == 0x0605_4B50 { return at }
            at -= 1
        }
        return nil
    }

    // MARK: Reading a file

    private static func contents(of entry: Entry, in data: Data) throws -> Data {
        let local = entry.localHeaderOffset
        guard local + 30 <= data.count, data.u32(local) == 0x0403_4B50 else { throw SkillImportError.notAZip }
        let start = local + 30 + Int(data.u16(local + 26)) + Int(data.u16(local + 28))
        guard start + entry.compressedSize <= data.count else { throw SkillImportError.notAZip }
        let stored = data.subdata(in: start..<(start + entry.compressedSize))
        let bytes: Data
        if entry.method == 0 {
            guard stored.count == entry.size else { throw SkillImportError.damagedZip }
            bytes = stored
        } else {
            bytes = try inflate(stored, size: entry.size)
        }
        guard crc32(bytes) == entry.crc else { throw SkillImportError.damagedZip }
        return bytes
    }

    /// Raw DEFLATE into a buffer of exactly the stated size: a bomb that says it is small is cut at
    /// that size and then fails its CRC.
    private static func inflate(_ input: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, size, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw SkillImportError.damagedZip }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: Writing

    private static func makeDirectories(_ path: [String], in root: URL) throws {
        var url = root
        for part in path {
            url.appendPathComponent(part, isDirectory: true)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw SkillImportError.unsafeEntry(path.joined(separator: "/")) }
                continue
            }
            guard mkdir(url.path, 0o755) == 0 else { throw SkillImportError.copyFailed }
        }
    }

    private static func write(_ bytes: Data, to path: [String], in root: URL) throws {
        let url = path.reduce(root) { $0.appendingPathComponent($1) }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        // O_EXCL: a name twice in one archive is refused rather than written over.
        guard fd >= 0 else { throw errno == EEXIST ? SkillImportError.unsafeEntry(path.joined(separator: "/")) : SkillImportError.copyFailed }
        defer { close(fd) }
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SkillImportError.copyFailed
                }
                offset += n
            }
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}
