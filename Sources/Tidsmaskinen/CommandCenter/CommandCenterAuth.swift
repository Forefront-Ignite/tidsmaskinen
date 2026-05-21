import Foundation

/// Thin wrapper around `KeychainStore` for the bearer token used against the
/// Command Center API. Tokens look like `cc_<base64>` and are minted by the
/// `mint-token` script in command-center.
enum CommandCenterAuth {
    static let keychainAccount = "command-center-token"

    static func loadToken() -> String? {
        guard let data = KeychainStore.getData(account: keychainAccount),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else {
            throw CommandCenterError.invalidToken
        }
        try KeychainStore.setData(data, account: keychainAccount)
    }

    static func clearToken() {
        _ = KeychainStore.delete(account: keychainAccount)
    }
}

enum CommandCenterError: Error, CustomStringConvertible {
    case missingToken
    case invalidToken
    case unauthorized
    case forbidden
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    var description: String {
        switch self {
        case .missingToken:        return "No Command Center API token configured."
        case .invalidToken:        return "Token is empty or unreadable."
        case .unauthorized:        return "Command Center rejected the token (401). Update it in Settings."
        case .forbidden:           return "Command Center denied the request (403)."
        case .http(let s, let b):  return "Command Center returned HTTP \(s): \(b.prefix(200))"
        case .transport(let m):    return "Network error talking to Command Center: \(m)"
        case .decoding(let m):     return "Could not decode Command Center response: \(m)"
        }
    }

    /// True when the cure is "user should refresh their token".
    var isAuthFailure: Bool {
        switch self {
        case .missingToken, .invalidToken, .unauthorized: return true
        default: return false
        }
    }
}
