import CryptoKit
import Foundation

/// What can be learned about a conversation file without decrypting it.
public struct ConversationFileHeader: Sendable, Hashable {
    public let id: UUID
    public let isEncrypted: Bool
    /// nil when encrypted.
    public let title: String?
    /// nil when encrypted.
    public let updatedAt: Date?
    /// nil when encrypted.
    public let messageCount: Int?
}

public enum ConversationFile {
    public static let format = "parley.conversation"
    public static let version = 1

    /// Always `<UUID>.json`; titles never appear in file names.
    public static func fileName(for id: UUID) -> String {
        id.uuidString + ".json"
    }

    // MARK: - Encode

    public static func encode(_ conversation: Conversation, encryption: EncryptionKey?) throws -> Data {
        guard let encryption else {
            let envelope = PlainEnvelope(
                format: format, version: version, encrypted: false, conversation: conversation
            )
            return try makeEncoder(pretty: true).encode(envelope)
        }

        let plaintext = try makeEncoder(pretty: false).encode(conversation)
        let aad = ConversationCrypto.aad(
            id: conversation.id, iterations: encryption.iterations, salt: encryption.salt
        )
        let combined = try ConversationCrypto.seal(plaintext, key: encryption.key, aad: aad)
        let envelope = EncryptedEnvelope(
            format: format,
            version: version,
            encrypted: true,
            id: conversation.id.uuidString.uppercased(),
            kdf: KDFParams(
                name: ConversationCrypto.kdfName,
                iterations: encryption.iterations,
                salt: encryption.salt.base64EncodedString()
            ),
            cipher: ConversationCrypto.cipherName,
            payload: combined.base64EncodedString()
        )
        return try makeEncoder(pretty: true).encode(envelope)
    }

    // MARK: - Peek

    public static func peek(_ data: Data) throws -> ConversationFileHeader {
        switch try parse(data) {
        case .plain(let conversation):
            return ConversationFileHeader(
                id: conversation.id,
                isEncrypted: false,
                title: conversation.title,
                updatedAt: conversation.updatedAt,
                messageCount: conversation.messages.count
            )
        case .encrypted(let header):
            return ConversationFileHeader(
                id: header.id, isEncrypted: true, title: nil, updatedAt: nil, messageCount: nil
            )
        }
    }

    // MARK: - Decode

    public static func decodePlain(_ data: Data) throws -> Conversation {
        switch try parse(data) {
        case .plain(let conversation): return conversation
        case .encrypted: throw ParleyError.corruptFile("the file is encrypted")
        }
    }

    /// Derives the key (slow, ~0.3–1 s), so call it off the main thread.
    public static func decodeEncrypted(_ data: Data, password: String) throws -> (Conversation, EncryptionKey) {
        let header = try encryptedHeader(data)
        let symmetric = try ConversationCrypto.deriveKey(
            password: password, salt: header.salt, iterations: header.iterations
        )
        let key = EncryptionKey(key: symmetric, salt: header.salt, iterations: header.iterations)
        return (try open(header, key: symmetric), key)
    }

    /// For re-opening with an already-derived key (e.g. after a fork). Fast.
    public static func decodeEncrypted(_ data: Data, key: EncryptionKey) throws -> Conversation {
        let header = try encryptedHeader(data)
        // The AAD is always built from the file's header, never from the key's parameters,
        // so a tampered header fails authentication even on this fast path.
        return try open(header, key: key.key)
    }

    // MARK: - Write

    /// Creates the parent directory (0700) if missing, then writes atomically: the bytes go to a
    /// 0600 temp file in the same directory, are fsynced and renamed over the destination.
    /// The final file is 0600.
    ///
    /// If `url` is a symbolic link, the file it points to is replaced (not the link itself), so
    /// encrypting through a linked path never leaves the plaintext target behind. A link that
    /// cannot be resolved (dangling or looping) is refused.
    public static func write(_ data: Data, to url: URL) throws {
        let destination = try resolvedDestination(url)
        let directory = destination.deletingLastPathComponent()
        try createDirectoryIfNeeded(directory)

        // Dot-prefixed and not ending in ".json", so library scans never list a half-written file.
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).parley-tmp")
        let tempPath = tempURL.path
        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError(errno) }

        var success = false
        defer {
            if !success { unlink(tempPath) }
        }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw posixError(errno)
                    }
                    offset += n
                }
            }
            // Ensure permissions regardless of umask.
            guard fchmod(fd, 0o600) == 0 else { throw posixError(errno) }
            guard fsync(fd) == 0 else { throw posixError(errno) }
        }
        guard rename(tempPath, destination.path) == 0 else { throw posixError(errno) }
        success = true
    }

    // MARK: - Internals

    static func makeEncoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    private struct PlainEnvelope: Codable {
        var format: String
        var version: Int
        var encrypted: Bool
        var conversation: Conversation
    }

    private struct KDFParams: Codable {
        var name: String
        var iterations: Int
        var salt: String
    }

    private struct EncryptedEnvelope: Codable {
        var format: String
        var version: Int
        var encrypted: Bool
        var id: String
        var kdf: KDFParams
        var cipher: String
        var payload: String
    }

    struct EncryptedHeader {
        let id: UUID
        let iterations: Int
        let salt: Data
        let payload: Data
    }

    enum Parsed {
        case plain(Conversation)
        case encrypted(EncryptedHeader)
    }

    /// Validates the envelope in a fixed order:
    /// invalid JSON -> corruptFile; not an object / wrong or missing format -> notAConversationFile;
    /// version not 1 -> unsupportedVersion; malformed fields -> corruptFile.
    static func parse(_ data: Data) throws -> Parsed {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ParleyError.corruptFile("invalid JSON")
        }
        guard let dict = object as? [String: Any],
              let fileFormat = dict["format"] as? String,
              fileFormat == format
        else {
            throw ParleyError.notAConversationFile
        }
        guard let fileVersion = dict["version"] as? Int else {
            throw ParleyError.corruptFile("missing version")
        }
        guard fileVersion == version else {
            throw ParleyError.unsupportedVersion(fileVersion)
        }
        guard let encrypted = dict["encrypted"] as? Bool else {
            throw ParleyError.corruptFile("missing encryption flag")
        }

        let decoder = makeDecoder()
        if !encrypted {
            do {
                return .plain(try decoder.decode(PlainEnvelope.self, from: data).conversation)
            } catch {
                throw ParleyError.corruptFile("invalid conversation data")
            }
        }

        let envelope: EncryptedEnvelope
        do {
            envelope = try decoder.decode(EncryptedEnvelope.self, from: data)
        } catch {
            throw ParleyError.corruptFile("invalid encrypted header")
        }
        guard let id = UUID(uuidString: envelope.id) else {
            throw ParleyError.corruptFile("invalid conversation id")
        }
        guard envelope.kdf.name == ConversationCrypto.kdfName else {
            throw ParleyError.corruptFile("unsupported key derivation function")
        }
        guard envelope.cipher == ConversationCrypto.cipherName else {
            throw ParleyError.corruptFile("unsupported cipher")
        }
        guard envelope.kdf.iterations > 0,
              envelope.kdf.iterations <= ConversationCrypto.maxIterations
        else {
            throw ParleyError.corruptFile("invalid iteration count")
        }
        guard let salt = Data(base64Encoded: envelope.kdf.salt), !salt.isEmpty else {
            throw ParleyError.corruptFile("invalid salt")
        }
        guard let payload = Data(base64Encoded: envelope.payload) else {
            throw ParleyError.corruptFile("invalid payload encoding")
        }
        return .encrypted(EncryptedHeader(
            id: id, iterations: envelope.kdf.iterations, salt: salt, payload: payload
        ))
    }

    private static func encryptedHeader(_ data: Data) throws -> EncryptedHeader {
        switch try parse(data) {
        case .encrypted(let header): return header
        case .plain: throw ParleyError.corruptFile("the file is not encrypted")
        }
    }

    private static func open(_ header: EncryptedHeader, key: SymmetricKey) throws -> Conversation {
        let aad = ConversationCrypto.aad(id: header.id, iterations: header.iterations, salt: header.salt)
        let plaintext = try ConversationCrypto.open(header.payload, key: key, aad: aad)
        let conversation: Conversation
        do {
            conversation = try makeDecoder().decode(Conversation.self, from: plaintext)
        } catch {
            // Never include decoding details: they could quote decrypted content.
            throw ParleyError.corruptFile("invalid decrypted payload")
        }
        guard conversation.id == header.id else {
            throw ParleyError.corruptFile("conversation id does not match header")
        }
        return conversation
    }

    /// `url` itself unless its last path component is a symbolic link, in which case the fully
    /// resolved target (whose directory then holds the temp file, keeping the rename on one volume).
    private static func resolvedDestination(_ url: URL) throws -> URL {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let err = errno
            if err == ENOENT { return url }   // new file
            throw posixError(err)
        }
        guard (st.st_mode & S_IFMT) == S_IFLNK else { return url }
        guard let resolved = realpath(path, nil) else {
            let err = errno
            throw posixError(err == ENOENT ? ELOOP : err)
        }
        defer { free(resolved) }
        let target = URL(fileURLWithPath: String(cString: resolved))
        var targetStat = stat()
        guard lstat(target.path, &targetStat) == 0 else { throw posixError(errno) }
        guard (targetStat.st_mode & S_IFMT) == S_IFREG else { throw posixError(EISDIR) }
        return target
    }

    private static func createDirectoryIfNeeded(_ directory: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
            }
            return
        }
        // Create each missing level ourselves so every directory we create is 0700.
        let parent = directory.deletingLastPathComponent()
        if parent.path != directory.path {
            try createDirectoryIfNeeded(parent)
        }
        if mkdir(directory.path, 0o700) != 0 {
            let err = errno
            if err != EEXIST { throw posixError(err) }
            return
        }
        // mkdir is subject to umask; make the mode exact.
        guard chmod(directory.path, 0o700) == 0 else { throw posixError(errno) }
    }

    private static func posixError(_ code: Int32) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
