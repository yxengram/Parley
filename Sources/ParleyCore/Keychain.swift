import Foundation
import Security

/// API keys live only in the local login keychain as generic passwords
/// (service `local.parley.chat.apikey`, account = provider UUID).
/// Items are never synchronizable (kSecAttrSynchronizable is left at its default, false).
public enum KeychainStore {
    public static let service = "local.parley.chat.apikey"
    /// MCP server secrets (MCPConfig.swift). A service of its own, so accounts cannot collide with
    /// API keys even when UUIDs match.
    public static let mcpService = "local.parley.chat.mcp"

    /// Upserts the key. An empty string deletes the item.
    public static func setAPIKey(_ key: String, for providerID: UUID) throws {
        try setValue(key, service: service, account: providerID.uuidString)
    }

    /// nil if no key is stored for this provider.
    public static func apiKey(for providerID: UUID) throws -> String? {
        try value(service: service, account: providerID.uuidString)
    }

    /// Deleting a key that does not exist is not an error.
    public static func deleteAPIKey(for providerID: UUID) throws {
        try deleteValue(service: service, account: providerID.uuidString)
    }

    // MARK: - Internals (service is a parameter so tests can probe with a separate service)

    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func setValue(_ value: String, service: String, account: String, label: String = "Parley API key") throws {
        if value.isEmpty {
            try deleteValue(service: service, account: account)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = label
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ParleyError.keychain(addStatus) }
        default:
            throw ParleyError.keychain(updateStatus)
        }
    }

    static func value(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw ParleyError.keychain(errSecDecode)
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw ParleyError.keychain(status)
        }
    }

    static func deleteValue(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ParleyError.keychain(status)
        }
    }
}
