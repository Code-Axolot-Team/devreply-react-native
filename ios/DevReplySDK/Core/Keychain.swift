import Foundation
import Security

/// The install token lives in the Keychain, this device only (spec 03). One entry per API host + public key,
/// and next to it the app's id for the signed-in user (`DevReply.login`), so a different person is noticed.
/// The Keychain outlives the app: a fresh install wipes it first (`wipeAfterReinstall`).
enum Keychain {
    private static let service = "com.devreply.sdk.install"

    static func token(for account: String) -> String? {
        string(for: account, service: service)
    }

    private static func string(for account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for account: String) {
        set(token, for: account, service: service)
    }

    private static func set(_ value: String, for account: String, service: String) {
        delete(account: account, service: service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Deletions still owed to the server (`DevReply.deleteUser` while it couldn't be reached): the old
    /// install tokens, retried until the server confirms. Their own service, so a reinstall's wipe keeps
    /// them: the user asked to be deleted, and that still happens.
    private static let pendingService = "com.devreply.sdk.pending-deletion"
    /// A small list: more than this many unconfirmed deletions on one device keeps the newest.
    static let maxPendingDeletions = 10

    static func pendingDeletions(for account: String) -> [String] {
        guard let json = string(for: account, service: pendingService),
              let tokens = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return tokens
    }

    static func setPendingDeletions(_ tokens: [String], for account: String) {
        let kept = Array(tokens.suffix(maxPendingDeletions))
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else {
            delete(account: account, service: pendingService)
            return
        }
        set(String(decoding: data, as: UTF8.self), for: account, service: pendingService)
    }

    /// The signed-in user this install belongs to (`DevReply.login`), if any.
    static func userID(for account: String) -> String? { token(for: "user|" + account) }
    static func setUserID(_ id: String, for account: String) { setToken(id, for: "user|" + account) }
    static func deleteUserID(for account: String) { deleteToken(for: "user|" + account) }

    /// Keychain items survive deleting the app: without this, the next person to install the app on this
    /// phone would get the previous user's chats. A marker file in Application Support (deleted with the
    /// app) tells a reinstall from a launch. Apps that already ran an SDK before this marker keep their
    /// install (they wrote the language to UserDefaults, which also goes with the app).
    static func wipeAfterReinstall(account: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "DevReply") else { return }
        let marker = dir.appending(path: "installed")
        if FileManager.default.fileExists(atPath: marker.path()) { return }
        let ranBefore = UserDefaults.standard.string(forKey: "devreply.locale.\(account)") != nil
        if !ranBefore {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: marker)
    }

    static func deleteToken(for account: String) {
        delete(account: account, service: service)
    }

    private static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
