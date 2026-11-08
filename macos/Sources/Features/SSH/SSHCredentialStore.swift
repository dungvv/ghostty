import Foundation
import Security
import OSLog

/// Stores SSH passwords in the login keychain, keyed by connection id.
///
/// Passwords never touch `ssh-connections.json`: that file is plain JSON in
/// Application Support and is meant to be readable, syncable and diffable.
/// The connection record only carries a `usesStoredPassword` flag so the rest
/// of the app can reason about auth without unlocking anything.
///
/// We deliberately use the legacy file-based keychain rather than the data
/// protection keychain. The latter needs the app to be signed with a stable
/// application identifier, which doesn't hold for local Debug builds, and a
/// credential store that only works in Release is worse than useless.
enum SSHCredentialStore {
    enum StoreError: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String?
                return message ?? "Keychain error \(status)."
            }
        }
    }

    /// Keychain service name. Scoped per bundle so a Debug build and a
    /// release install don't fight over the same items.
    static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty") + ".ssh"
    }

    private static func account(for id: UUID) -> String {
        id.uuidString
    }

    private static func baseQuery(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id),
        ]
    }

    // MARK: - API

    /// Whether a password is stored.
    ///
    /// This asks only for attributes, never the data, so it doesn't prompt
    /// the user for keychain access. Safe to call while drawing a view.
    static func hasPassword(for id: UUID) -> Bool {
        var query = baseQuery(for: id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Read the password back. This may prompt for keychain access the first
    /// time, so never call it from a view body.
    static func password(for id: UUID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                SSHProcess.logger.warning(
                    "keychain read failed status=\(status, privacy: .public)")
            }
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store (or replace) the password for a connection.
    static func setPassword(_ password: String, for id: UUID, label: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        // Replace rather than update so we don't have to care whether an item
        // already exists.
        SecItemDelete(baseQuery(for: id) as CFDictionary)

        var attributes = baseQuery(for: id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Ghostty SSH — \(label)"
        attributes[kSecAttrDescription as String] = "SSH password"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Remove the password for a connection. Missing items are not an error.
    static func removePassword(for id: UUID) {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            SSHProcess.logger.warning(
                "keychain delete failed status=\(status, privacy: .public)")
        }
    }
}
