import Foundation
import Security

/// Token storage for the GitHub personal access token.
public enum Keychain {
    public static let service = "com.runway.app"
    public static let account = "github.com"

    public enum KeychainError: Error, LocalizedError, Sendable {
        case encodingFailed
        case writeFailed(OSStatus)
        case deleteFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Token could not be encoded as UTF-8."
            case .writeFailed(let status):
                return "Keychain write failed (OSStatus \(status))."
            case .deleteFailed(let status):
                return "Keychain delete failed (OSStatus \(status))."
            }
        }
    }

    /// Base query for every operation.
    ///
    /// Two keychain backends are in play and neither works alone:
    ///
    /// * The **data-protection keychain** (`kSecUseDataProtectionKeychain: true`)
    ///   scopes items by code identity and returns an error rather than blocking
    ///   on an approval panel — which matters, because an `LSUIElement`
    ///   accessory cannot reliably present one. But it requires the
    ///   `keychain-access-groups` / `application-identifier` entitlement, and an
    ///   ad-hoc signed binary has neither: `SecItemAdd` returns `-34018`
    ///   (`errSecMissingEntitlement`).
    ///
    /// * The **legacy file-based keychain** works without entitlements, but its
    ///   per-item ACL is keyed to the writing binary's signature. A binary not on
    ///   the ACL triggers a SecurityAgent prompt.
    ///
    /// So: prefer data-protection when entitlements make it available, fall back
    /// to legacy otherwise. `make app` keeps working for anyone who clones the
    /// repo without a paid signing identity, and upgrades silently if the app is
    /// ever properly signed.
    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }

    /// Store the token, replacing any existing one.
    public static func store(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in [true, false] {
            var query = baseQuery(dataProtection: dataProtection)
            // Delete-then-add keeps the accessibility attribute authoritative.
            SecItemDelete(query as CFDictionary)

            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess {
                TokenCache.shared.invalidate()
                return
            }
            lastStatus = status
        }
        throw KeychainError.writeFailed(lastStatus)
    }

    /// Read the token back.
    public static func load() -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var out: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data,
               let token = String(data: data, encoding: .utf8) {
                return token
            }
        }
        return nil
    }

    /// Copy a token found in the legacy keychain into the data-protection one.
    @discardableResult
    public static func migrateLegacyItem() -> Bool {
        var query = baseQuery(dataProtection: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8) else { return false }

        return (try? store(token)) != nil
    }

    /// Remove the token from both keychains.
    public static func delete() throws {
        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                lastStatus = status
            }
        }
        TokenCache.shared.invalidate()
        guard lastStatus == errSecSuccess else {
            throw KeychainError.deleteFailed(lastStatus)
        }
    }

    /// What kind of token this looks like, purely from its prefix.
    ///
    /// Only ever used to warn in Settings — the API is the real authority on
    /// whether a token works, and a token of an unrecognised shape is still
    /// accepted and tried.
    public static func describe(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("github_pat_") { return "fine-grained personal access token" }
        if trimmed.hasPrefix("ghp_") { return "classic personal access token" }
        if trimmed.hasPrefix("gho_") { return "OAuth token" }
        if trimmed.hasPrefix("ghs_") { return "GitHub App installation token" }
        return nil
    }
}

/// Process-wide token cache.
public final class TokenCache: @unchecked Sendable {
    public static let shared = TokenCache()

    private let lock = NSLock()
    /// Double optional: `nil` is "never read", `.some(nil)` is "read, and empty".
    private var cached: String??

    private init() {}

    /// When true, the keychain is never touched and `token()` returns nil.
    ///
    /// Behind the same lock as `cached`. It was a bare `var` on an
    /// `@unchecked Sendable` class — read inside the lock, written outside it,
    /// from the main actor, while `GitHubClient`'s token provider reads it from
    /// whatever thread the poll happens to be on. `@unchecked` is exactly the
    /// annotation that stops the compiler pointing that out.
    private var disabled = false

    public var isDisabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return disabled
        }
        set {
            lock.lock()
            disabled = newValue
            lock.unlock()
        }
    }

    public func token() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if disabled { return nil }
        if let cached { return cached }
        let value = Keychain.load()
        cached = value
        return value
    }

    /// Forget the cached value; the next read goes back to the keychain.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
