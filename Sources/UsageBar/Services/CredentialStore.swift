import Foundation
import Security

struct StoredCredential: Codable, Equatable {
    var kind: CredentialKind
    var value: String
}

protocol CredentialStoreType: AnyObject {
    func save(_ credential: StoredCredential, for provider: ProviderKind) throws
    func load(for provider: ProviderKind) -> StoredCredential?
    func delete(for provider: ProviderKind)
}

final class CredentialStore: CredentialStoreType {
    private let service = "com.spicyclaw.UsageBar"

    func save(_ credential: StoredCredential, for provider: ProviderKind) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]

        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status)
        }
    }

    func load(for provider: ProviderKind) -> StoredCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { return nil }
        guard let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    func delete(for provider: ProviderKind) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum CredentialStoreError: LocalizedError {
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown keychain error"
            return "Keychain save failed (\(status)): \(message)"
        }
    }
}
