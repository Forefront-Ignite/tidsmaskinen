import Foundation
import Security

enum KeychainStore {
    static let service = "se.forefront.tidsmaskinen"

    enum KeychainError: Error, CustomStringConvertible {
        case unhandled(OSStatus)
        case decoding

        var description: String {
            switch self {
            case .unhandled(let s): return "Keychain error \(s)"
            case .decoding: return "Keychain value could not be decoded"
            }
        }
    }

    static func setData(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            // Bind the item to this device so the MS Graph refresh token
            // doesn't ride iCloud Keychain to another Mac (where TCC grants
            // and the bundled cert's leaf hash wouldn't match anyway).
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandled(updateStatus)
        }
    }

    static func getData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func delete(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func setCodable<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        try setData(data, account: account)
    }

    static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = getData(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
