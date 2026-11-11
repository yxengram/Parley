import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A derived conversation key plus the KDF parameters it was derived with.
/// Not Codable and never persisted: it lives in memory only while a conversation is unlocked.
public struct EncryptionKey: Sendable {
    public let key: SymmetricKey
    public let salt: Data
    public let iterations: Int

    public init(key: SymmetricKey, salt: Data, iterations: Int) {
        self.key = key
        self.salt = salt
        self.iterations = iterations
    }
}

/// Internal failures that are not about a specific file (KDF/RNG problems).
/// Messages never contain secrets or plaintext.
enum ConversationCryptoError: LocalizedError {
    case invalidIterations(Int)
    case emptySalt
    case keyDerivationFailed(Int32)
    case randomGenerationFailed(Int32)
    case sealFailed

    var errorDescription: String? {
        switch self {
        // Shown only (encrypt and password sheets): in the interface language.
        case .invalidIterations(let n): return String(localized: "Invalid key derivation iteration count \(n).")
        case .emptySalt: return String(localized: "Key derivation salt is empty.")
        case .keyDerivationFailed(let s):
            // A String, not an Int: String(localized:) would group the digits ("-25,300").
            let status = String(s)
            return String(localized: "Key derivation failed (status \(status)).")
        case .randomGenerationFailed(let s):
            let status = String(s)
            return String(localized: "Secure random generation failed (status \(status)).")
        case .sealFailed: return String(localized: "Encryption failed.")
        }
    }
}

public enum ConversationCrypto {
    public static let kdfName = "PBKDF2-HMAC-SHA256"
    public static let cipherName = "AES-256-GCM"
    public static let defaultIterations = 600_000

    static let keyByteCount = 32
    static let saltByteCount = 16
    /// Upper bound accepted when reading a file, so a hostile header cannot make us spin forever.
    static let maxIterations = 50_000_000

    /// PBKDF2-HMAC-SHA256 via CommonCrypto, 32-byte output.
    /// The password is NFC-normalized first so the same visible password always yields the same key.
    public static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations > 0, iterations <= Int(UInt32.max) else {
            throw ConversationCryptoError.invalidIterations(iterations)
        }
        guard !salt.isEmpty else { throw ConversationCryptoError.emptySalt }

        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: keyByteCount)
        defer {
            // Best-effort scrub of the temporary copy.
            for i in derived.indices { derived[i] = 0 }
        }

        let status: Int32 = passwordBytes.withUnsafeBufferPointer { pwd in
            pwd.withMemoryRebound(to: CChar.self) { pwdChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdChars.baseAddress, pwdChars.count,
                    saltBytes, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived, derived.count
                )
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw ConversationCryptoError.keyDerivationFailed(status)
        }
        return SymmetricKey(data: derived)
    }

    /// Creates a fresh random 16-byte salt (SecRandomCopyBytes) and derives a key from it.
    public static func newKey(password: String, iterations: Int = defaultIterations) throws -> EncryptionKey {
        let salt = try randomBytes(count: saltByteCount)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        return EncryptionKey(key: key, salt: salt, iterations: iterations)
    }

    /// AES-256-GCM with a fresh random nonce. Returns `SealedBox.combined` (nonce | ciphertext | tag).
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)
        guard let combined = box.combined else { throw ConversationCryptoError.sealFailed }
        return combined
    }

    /// Opens a combined sealed box. Authentication failure (wrong key, tampered ciphertext or AAD)
    /// throws `ParleyError.wrongPassword`; a structurally invalid box throws `corruptFile`.
    public static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw ParleyError.corruptFile("encrypted payload is malformed")
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch CryptoKitError.authenticationFailure {
            throw ParleyError.wrongPassword
        } catch {
            throw ParleyError.corruptFile("encrypted payload could not be opened")
        }
    }

    /// The additional authenticated data that binds the file header to the ciphertext:
    /// `parley.conversation|1|<UUID>|PBKDF2-HMAC-SHA256|<iterations>|<salt base64>|AES-256-GCM`.
    /// Used by both encode and decode so the bytes are always identical.
    static func aad(id: UUID, iterations: Int, salt: Data) -> Data {
        let parts = [
            ConversationFile.format,
            String(ConversationFile.version),
            id.uuidString.uppercased(),
            kdfName,
            String(iterations),
            salt.base64EncodedString(),
            cipherName,
        ]
        return Data(parts.joined(separator: "|").utf8)
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw ConversationCryptoError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}
