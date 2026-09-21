#if canImport(Security)
import Foundation
import Security

/// Keeps the `Session` in the Keychain as one generic-password item, JSON
/// encoded. The app and the share extension read the same item by using the
/// same service name and an app-group access group.
///
/// The item is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: the share
/// extension only ever runs with UI, i.e. while the device is unlocked, so it
/// needs no looser accessibility, and `ThisDeviceOnly` keeps the DPoP private
/// key out of iCloud Keychain backup and device-to-device migration.
public final class KeychainSessionStore: SessionStore, Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: Identifies the item, e.g. the app's bundle identifier.
    ///   - account: Distinguishes items within the service; one account is
    ///     enough since there is only ever one signed-in session.
    ///   - accessGroup: The Keychain access group shared with the extension
    ///     (`<team id>.<app group>`). `nil` keeps the item private to the
    ///     calling process, which is what tests want.
    public init(service: String, account: String = "session", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> Session? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return try JSONDecoder().decode(Session.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)

        // Update first rather than delete-then-add: a delete followed by a
        // failed add would lose the session (and the refresh token in it,
        // already spent at the server) entirely. Updating also re-sets
        // kSecAttrAccessible, which migrates an item an older app version
        // wrote with a different accessibility.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, updateAttributes as CFDictionary)
        guard updateStatus != errSecSuccess else { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// The attributes that identify our one item.
    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// A Keychain call failed. `status` is the raw `OSStatus` for logs; the
/// description is the system's own message for it.
public struct KeychainError: LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        var message = "error \(status)"
        if let systemMessage = SecCopyErrorMessageString(status, nil) {
            message = systemMessage as String
        }
        return "Couldn't access the Keychain (\(message))."
    }
}
#endif
