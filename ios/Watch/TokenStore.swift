import Foundation
// Security's kSec constants are C globals Swift 6 cannot prove constant.
@preconcurrency import Security

/// The Watch's token, in the Watch's own keychain: a generic password for
/// this install, readable after the Watch's first unlock and only on this
/// device, so it never moves to another by backup or sync. Calls return the
/// keychain's status, for the log; never the token.
struct TokenStore: Sendable {
    static let service = "org.durableassistants.watch-token"

    /// The install's address: a Watch built for another keeps another token.
    let account: String

    init(base: URL) {
        account = base.absoluteString
    }

    /// Names the one item, for reading and deleting.
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    /// The item to add.
    func item(_ token: String) -> [String: Any] {
        query.merging([kSecValueData as String: Data(token.utf8),
                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
    }

    func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces any token kept before: a new token is a new connection.
    @discardableResult
    func save(_ token: String) -> OSStatus {
        delete()
        return SecItemAdd(item(token) as CFDictionary, nil)
    }

    @discardableResult
    func delete() -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
