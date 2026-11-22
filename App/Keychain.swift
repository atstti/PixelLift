import Foundation
import PixelLiftCore
import Security

enum ReplicateKeychain {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.pixelliftai.macos",
        kSecAttrAccount as String: "replicate"
    ]

    static func read() throws -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw KeychainFailure() }
        return token
    }

    static func save(_ token: String) throws {
        guard !token.isEmpty else { throw PixelLiftError.missingToken }
        guard token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw PixelLiftError.invalidToken }
        let data = Data(token.utf8)
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure() }
        var query = item
        query[kSecValueData as String] = data
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw KeychainFailure() }
    }

    static func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure() }
    }
}

struct KeychainFailure: LocalizedError {
    var errorDescription: String? { String(localized: "macOSキーチェーンにアクセスできませんでした。") }
}
