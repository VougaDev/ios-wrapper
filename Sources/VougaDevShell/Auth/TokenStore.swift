import Foundation
import Security

/// Where the refresh token is kept: the Keychain on the phone, a variable in the tests.
public protocol SecretVault: AnyObject {
    func read() -> String?
    func write(_ value: String?)
}

/// THE APP'S REFRESH TOKEN, IN THE KEYCHAIN, readable after the first unlock and never restored to another phone
/// (`ThisDeviceOnly`), as Android seals it with a Keystore key. the account service rotates it: every refresh answers a new one and the
/// old one is spent, so [save] is called with each answer and the new token replaces the old at once.
///
/// The access token is never written: it lives a few minutes and is traded at once for the site's session.
public final class TokenStore {
    let vault: SecretVault

    public init(vault: SecretVault) { self.vault = vault }

    public func refreshToken() -> String? { vault.read().flatMap { $0.isEmpty ? nil : $0 } }

    /// A new (rotated) refresh token; a blank one keeps the current token, as OAuth allows a refresh to answer none.
    public func save(_ refreshToken: String?) {
        guard let refreshToken, !refreshToken.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        vault.write(refreshToken)
    }

    public func clear() { vault.write(nil) }

    public var signedIn: Bool { refreshToken() != nil }
}

/// One generic-password item of the app's Keychain.
public final class KeychainVault: SecretVault {
    let service: String
    let account = "refresh_token"

    public init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var found: CFTypeRef?
        var ask = query
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(ask as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?) {
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
