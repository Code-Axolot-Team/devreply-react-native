import Foundation
import Security

/// The install token lives in the Keychain, this device only (spec 03). One entry per API host + public key,
/// and next to it the app's id for the signed-in user (`DevReply.login`), so a different person is noticed.
/// The Keychain outlives the app: a fresh install wipes it first (`wipeAfterReinstall`).
enum Keychain {
    private static let service = "com.devreply.sdk.install"

    static func token(for account: String) -> String? {
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
        deleteToken(for: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
