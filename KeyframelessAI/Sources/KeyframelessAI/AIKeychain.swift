import Foundation
import Security

public enum AIKeychainError: Error {
    case unexpectedStatus(OSStatus)
    case dataEncodingFailed
}

public enum AIKeychain {
    private static let service = "com.overpolish.ai-keys"

    public static func save(_ key: String, for provider: AIProvider) throws {
        guard let data = key.data(using: .utf8) else {
            throw AIKeychainError.dataEncodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AIKeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIKeychainError.unexpectedStatus(addStatus)
        }
        Task { @MainActor in AIKeyState.shared.refresh() }
    }

    public static func load(_ provider: AIProvider) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw AIKeychainError.unexpectedStatus(status)
        }
    }

    public static func delete(_ provider: AIProvider) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AIKeychainError.unexpectedStatus(status)
        }
        Task { @MainActor in AIKeyState.shared.refresh() }
    }

    public static func providersWithKeys() -> [AIProvider] {
        AIProvider.allCases.filter { (try? load($0)) != nil }
    }
}
