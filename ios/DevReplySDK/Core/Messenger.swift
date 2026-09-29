import Foundation
import UIKit
import Observation

/// App-wide messenger state: the install, the config, the user's conversations.
@MainActor @Observable
final class Messenger {
    static let shared = Messenger()

    private(set) var publicKey: String?
    private(set) var client: APIClient?
    private(set) var config: MessengerConfig = .placeholder
    private(set) var conversations: [Conversation] = []
    private(set) var isLoading = false
    private(set) var lastError: DevReplyError?
    private(set) var profile: Profile?
    /// The messenger is on screen / this conversation is on screen (no banners for what the user sees).
    var isPresented = false
    var visibleConversation: UUID?
    private var watching: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    var unreadCount: Int { conversations.reduce(0) { $0 + $1.unread } }

    private var registering: Task<String, Error>?
    /// A refused public key (unknown or revoked) isn't retried in a loop: after 1 min, 5 min, 30 min,
    /// then every 6 h, and again on the next launch (spec 05).
    private var keyRefusals = 0
    private var keyRetryAt: Date?

    nonisolated static func keyRetryDelay(afterRefusals count: Int) -> TimeInterval {
        let steps: [TimeInterval] = [60, 300, 1800]
        return count < steps.count ? steps[count] : 6 * 3600
    }

    func configure(publicKey: String, apiURL: URL) {
        self.publicKey = publicKey
        client = APIClient(baseURL: apiURL)
        registering = nil
        keyRefusals = 0
        keyRetryAt = nil
        conversations = []
        _ = L10n.shared // the device's language, and its changes, from now on
        config = Self.cachedConfig(for: publicKey) ?? .placeholder
        _ = BrandFont.register
        // Register early so the first open is instant, and pick up unread replies.
        PushManager.shared.start()
        UnreadBubble.shared.start()
        startWatchingForReplies()
        Task {
            if let user = hostUser { try? await saveProfile(name: user.name, email: user.email) }
            await flushAttributes()
            await refresh()
            await PushManager.shared.sendTokenIfNeeded()
        }
    }

    private var keychainAccount: String? {
        guard let publicKey, let client else { return nil }
        return "\(client.baseURL.host() ?? "api")|\(publicKey)"
    }

    /// The install token, registering this install first if needed. Concurrent callers share one registration.
    func token() async throws -> String {
        guard let client, let publicKey, let account = keychainAccount else {
            throw DevReplyError.invalid("Call DevReply.configure(_:) first")
        }
        if let stored = Keychain.token(for: account) { return stored }
        if let registering { return try await registering.value }
        if let at = keyRetryAt, Date() < at { throw DevReplyError.invalidPublicKey }
        let device = DeviceInfo.current
        let task = Task { () throws -> String in
            do {
                let install = try await client.registerInstall(publicKey: publicKey, device: device)
                Keychain.setToken(install.token, for: account)
                UserDefaults.standard.set(device.json["locale"], forKey: "devreply.locale.\(account)")
                keyRefusals = 0
                keyRetryAt = nil
                return install.token
            } catch DevReplyError.invalidPublicKey {
                if keyRefusals == 0 {
                    print("DevReply: this public key isn't recognised: \(publicKey.prefix(9))… Check the key in DevReply → Settings.")
                }
                keyRetryAt = Date().addingTimeInterval(Self.keyRetryDelay(afterRefusals: keyRefusals))
                keyRefusals += 1
                throw DevReplyError.invalidPublicKey
            }
        }
        registering = task
        defer { registering = nil }
        return try await task.value
    }

    /// Runs `call` with the token. If the token was revoked, registers again once and retries.
    func authorized<T>(_ call: (APIClient, String) async throws -> T) async throws -> T {
        guard let client else { throw DevReplyError.invalid("Call DevReply.configure(_:) first") }
        do {
            return try await call(client, try await token())
        } catch DevReplyError.unauthenticated {
            if let account = keychainAccount { Keychain.deleteToken(for: account) }
            return try await call(client, try await token())
        }
    }

    /// The chat's language changed (the app's `setLocale`, or the device's language): tell the server
    /// once, so the team sees it. Only after this install is registered; registration sends it too.
    func syncLocale() {
        guard client != nil, let account = keychainAccount, Keychain.token(for: account) != nil else { return }
        let tag = L10n.currentTag
        let key = "devreply.locale.\(account)"
        guard UserDefaults.standard.string(forKey: key) != tag else { return }
        Task {
            if (try? await authorized({ try await $0.updateLocale(token: $1, locale: tag) })) != nil {
                UserDefaults.standard.set(tag, forKey: key)
            }
        }
    }

    /// The app opened a DevReply link (`DevReply.handle`): tell the server, so Settings shows the deep link works.
    func reportDeepLinkOpened() {
        guard client != nil else { return }
        Task { _ = try? await authorized { try await $0.deepLinkOpened(token: $1) } }
    }

    func refresh() async {
        guard client != nil else { return }
        isLoading = conversations.isEmpty
        defer { isLoading = false }
        do {
            async let config = authorized { try await $0.config(token: $1) }
            async let list = authorized { try await $0.conversations(token: $1) }
            async let me = authorized { try await $0.profile(token: $1) }
            let (c, l, p) = try await (config, list, me)
            profile = p
            if c != self.config {
                self.config = c
                Self.cache(c, for: publicKey)
            }
            conversations = l
            lastError = nil
            syncLocale()
        } catch let error as DevReplyError {
            lastError = error
        } catch {
            lastError = .network
        }
    }

    /// A name is required before the first message (spec 05), unless the app supplied one.
    var needsName: Bool { (profile?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// Saves what the user typed (or what the host app passed to `DevReply.setUser`).
    func saveProfile(name: String?, email: String?) async throws {
        profile = try await authorized { try await $0.updateProfile(token: $1, name: name, email: email) }
    }

    /// Name, email and attributes from the host app, applied once the install exists.
    private var hostUser: (name: String?, email: String?)?
    private var pendingAttributes: [String: DevReplyAttribute?] = [:]

    func setAttributes(_ attributes: [String: DevReplyAttribute?]) {
        pendingAttributes.merge(attributes) { _, new in new }
        guard client != nil else { return }
        Task { await flushAttributes() }
    }

    private func flushAttributes() async {
        let batch = pendingAttributes
        guard !batch.isEmpty else { return }
        if (try? await authorized({ try await $0.updateProfile(token: $1, name: nil, email: nil, attributes: batch) })) != nil {
            for key in batch.keys where pendingAttributes[key] == batch[key] { pendingAttributes.removeValue(forKey: key) }
        }
    }

    func setUser(name: String?, email: String?) {
        hostUser = (name, email)
        guard client != nil else { return }
        Task { try? await saveProfile(name: name, email: email) }
    }

    func loadProfileIfNeeded() async {
        guard profile == nil else { return }
        profile = try? await authorized { try await $0.profile(token: $1) }
    }

    // The last config per public key, in Caches (spec 05: fetched on open and cached).
    private static func cacheURL(for publicKey: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "devreply-config-\(publicKey).json")
    }

    private static func cachedConfig(for publicKey: String) -> MessengerConfig? {
        guard let url = cacheURL(for: publicKey), let data = try? Data(contentsOf: url) else { return nil }
        return try? APIClient.decoder.decode(MessengerConfig.self, from: data)
    }

    private static func cache(_ config: MessengerConfig, for publicKey: String?) {
        guard let publicKey, let url = cacheURL(for: publicKey) else { return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try? encoder.encode(config).write(to: url, options: .atomic)
    }

    /// While the app is open and the messenger is closed, look for new replies every 30 s and show
    /// the in-app banner. Pushes cover the rest (and arrive faster when they're on).
    private func startWatchingForReplies() {
        watching?.cancel()
        if foregroundObserver == nil {
            // Back in the app: pick up replies that came while it was away (the unread bubble shows them).
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in await Messenger.shared.refresh() }
            }
        }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, UIApplication.shared.applicationState == .active, !self.isPresented,
                      !self.conversations.isEmpty else { continue }
                let before = Dictionary(uniqueKeysWithValues: self.conversations.map { ($0.id, $0.unread) })
                await self.refresh()
                if let fresh = self.conversations.first(where: { $0.unread > (before[$0.id] ?? 0) && $0.lastAuthor != "user" }) {
                    InAppBanner.shared.show(title: self.config.teamName, body: fresh.lastText ?? t("banner.new_reply"), conversationID: fresh.id)
                }
            }
        }
    }

    func upsert(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        conversations.sort { $0.lastMessageAt > $1.lastMessageAt }
    }
}
