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
    private var backgroundObserver: NSObjectProtocol?

    // MARK: Live updates (spec 05, 0.5.0)

    /// The socket is up (`ready` came): the open chat's 3 s poll pauses.
    private(set) var isLive = false
    /// The conversation on screen, for live messages (set by ConversationView).
    @ObservationIgnored weak var visibleModel: ConversationModel?
    /// The last message id this install has seen (ids are time-ordered UUID v7): the socket resumes after it.
    @ObservationIgnored private(set) var lastSeenMessage: UUID?
    /// Live messages already applied to the list (a backlog can repeat one).
    @ObservationIgnored private var appliedLive: [UUID] = []

    @ObservationIgnored private(set) lazy var live: LiveConnection = {
        let connection = LiveConnection(environment: .standard(
            ticket: { try await Messenger.shared.liveTicket() },
            session: { Messenger.shared.client?.session ?? .shared }
        ))
        connection.lastSeen = { Messenger.shared.lastSeenMessage }
        connection.onEvent = { Messenger.shared.handleLive($0) }
        connection.onStateChange = { Messenger.shared.liveStateChanged($0) }
        return connection
    }()

    /// Tests: the live connection with a fake socket and clock.
    func useLiveForTesting(_ connection: LiveConnection) {
        connection.lastSeen = { [weak self] in self?.lastSeenMessage }
        connection.onEvent = { [weak self] in self?.handleLive($0) }
        connection.onStateChange = { [weak self] in self?.liveStateChanged($0) }
        live = connection
    }

    private func liveTicket() async throws -> URL {
        do {
            return try await authorized { try await $0.liveTicket(token: $1) }.url
        } catch DevReplyError.unavailable, DevReplyError.notFound, DevReplyError.invalid {
            throw LiveUnavailable()
        } catch is DecodingError {
            // Not a live-capable server (no `url`): poll.
            throw LiveUnavailable()
        }
    }

    private func liveStateChanged(_ state: LiveConnection.State) {
        let wasLive = isLive
        isLive = state == .live
        // Just connected: whatever came between the thread's last load and `ready` (a first connection has
        // no `after` to resume from).
        if isLive, !wasLive, let model = visibleModel { Task { await model.load() } }
    }

    /// Only while the messenger is open and the app is in the foreground.
    private func startLive() {
        guard client != nil, isPresented else { return }
        live.start()
    }

    /// A message id this install has seen (a live event, a thread load, a send).
    func saw(_ id: UUID) {
        if let last = lastSeenMessage, last.uuidString.lowercased() >= id.uuidString.lowercased() { return }
        lastSeenMessage = id
    }

    func handleLive(_ event: LiveEvent) {
        guard case .message(let conversationID, let message) = event else { return }
        saw(message.id)
        let onScreen = visibleModel?.conversation?.id == conversationID
        if onScreen, let model = visibleModel {
            model.receive(message)
            if !message.isFromUser { live.send(LiveEvent.readFrame(conversationID)) }
        }
        guard !appliedLive.contains(message.id) else { return }
        appliedLive.append(message.id)
        if appliedLive.count > 200 { appliedLive.removeFirst(appliedLive.count - 200) }
        if let known = conversations.first(where: { $0.id == conversationID }) {
            let updated = known.receiving(message, onScreen: onScreen)
            if updated != known { upsert(updated) }
        } else {
            // A conversation this device doesn't list yet (started on another device): the list from the server.
            Task { await refresh() }
        }
    }

    var unreadCount: Int { conversations.reduce(0) { $0 + $1.unread } }

    /// `DevReply.isAvailable`: configured, and the team hasn't switched the chat off.
    var isAvailable: Bool { Self.isAvailable(configured: client != nil, config: config) }

    /// Before any config (none cached yet) the chat counts as on: the placeholder is `enabled`.
    nonisolated static func isAvailable(configured: Bool, config: MessengerConfig) -> Bool {
        configured && config.enabled
    }

    // MARK: This presentation (`DevReply.present(category:message:attributes:askName:)`)

    /// Prefills the composer of a new conversation started in this presentation, until one starts.
    @ObservationIgnored private(set) var presentationMessage: String?
    /// Goes as `context` with this presentation's first new conversation.
    @ObservationIgnored private(set) var presentationContext: [String: DevReplyAttribute] = [:]
    /// `present(askName: false)`: no name form while this presentation is open (the user can still add an email).
    private(set) var presentationSkipsName = false
    /// A full-screen cover (the photo viewer) is over the messenger: its disappearing isn't a close.
    @ObservationIgnored var isCovered = false

    func setPresentation(message: String?, attributes: [String: DevReplyAttribute], askName: Bool = true) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        presentationMessage = (text?.isEmpty ?? true) ? nil : message
        presentationContext = DevReplyAttribute.context(attributes)
        presentationSkipsName = !askName
    }

    func messengerAppeared() {
        guard !isPresented else { return }
        isPresented = true
        startLive()
        Events.emit(.messengerOpened)
    }

    func messengerDisappeared() {
        guard isPresented, !isCovered else { return }
        isPresented = false
        live.stop()
        presentationMessage = nil
        presentationContext = [:]
        presentationSkipsName = false
        Events.emit(.messengerClosed)
    }

    /// `POST /v1/conversations` succeeded: the presentation's message and context are used up.
    func conversationStarted(_ id: UUID, category: DevReplyCategory?) {
        presentationMessage = nil
        presentationContext = [:]
        Events.emit(.conversationStarted(conversationID: id, category: category))
        Events.emit(.messageSent(conversationID: id))
    }

    func messageSent(conversationID id: UUID) {
        Events.emit(.messageSent(conversationID: id))
    }

    private var registering: Task<String, Error>?
    /// A refused public key (unknown or revoked) isn't retried in a loop: after 1 min, 5 min, 30 min,
    /// then every 6 h, and again on the next launch (spec 05).
    private var keyRefusals = 0
    private var keyRetryAt: Date?

    nonisolated static func keyRetryDelay(afterRefusals count: Int) -> TimeInterval {
        let steps: [TimeInterval] = [60, 300, 1800]
        return count < steps.count ? steps[count] : 6 * 3600
    }

    /// A notification tap that came before `configure`: opened right after it.
    @ObservationIgnored private var pendingConversation: UUID?

    /// A tap on a DevReply notification: open its conversation (after `configure` if it came first), and
    /// tell the server once per launch that taps reach the chat.
    func openWhenConfigured(conversationID id: UUID) {
        if client == nil {
            pendingConversation = id
        } else {
            DevReply.openWhenReady(conversationID: id, attempts: 10)
            reportPushOpened()
        }
    }

    @ObservationIgnored private var reportedPushOpened = false

    private func reportPushOpened() {
        guard client != nil, !reportedPushOpened else { return }
        reportedPushOpened = true
        Task { _ = try? await authorized { try await $0.pushOpened(token: $1) } }
    }

    func configure(publicKey: String, apiURL: URL) {
        self.publicKey = publicKey
        client = APIClient(baseURL: apiURL)
        if let account = keychainAccount {
            Keychain.wipeAfterReinstall(account: account)
            // Signed in as someone else than this install's user (the app called login before configure).
            if let id = hostUserID, let current = Keychain.userID(for: account), current != id { forgetInstall() }
        }
        registering = nil
        live.stop()
        lastSeenMessage = nil
        appliedLive = []
        keyRefusals = 0
        keyRetryAt = nil
        conversations = []
        _ = L10n.shared // the device's language, and its changes, from now on
        config = Self.cachedConfig(for: publicKey) ?? .placeholder
        _ = BrandFont.register
        // Deletions the server didn't confirm yet (`deleteUser` offline): with their own old tokens.
        Task { await retryPendingDeletions() }
        // Register early so the first open is instant, and pick up unread replies.
        PushManager.shared.start()
        UnreadBubble.shared.start()
        startWatchingForReplies()
        if let id = pendingConversation {
            pendingConversation = nil
            DevReply.openWhenReady(conversationID: id, attempts: 10)
            reportPushOpened()
        }
        Task {
            await sendUserID()
            if let user = hostUser { try? await saveProfile(name: user.name, email: user.email) }
            await flushAttributes()
            await refresh()
            await PushManager.shared.sendTokenIfNeeded()
        }
    }

    /// Tests: the API through `client` (a stubbed session), without push, the unread bubble or polling.
    func useForTesting(publicKey: String, client: APIClient) {
        self.publicKey = publicKey
        self.client = client
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
        let deviceKey = Keychain.deviceKey(for: account)
        let task = Task { () throws -> String in
            do {
                let install = try await client.registerInstall(publicKey: publicKey, device: device, deviceKey: deviceKey)
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
                // Switched off in the dashboard: an open messenger closes itself (MessengerView), the
                // unread bubble hides (UnreadBubble).
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
    var needsName: Bool {
        !presentationSkipsName && (profile?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

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

    // MARK: Signed-in user (spec 03)

    /// The app's id for the signed-in user (`DevReply.login`).
    private var hostUserID: String?

    /// Returns the task that sends the id (tests wait for it).
    @discardableResult
    func login(userID: String) -> Task<Void, Never>? {
        let id = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        // Another person on this device: they start from a new, empty install.
        if let account = keychainAccount, let current = Keychain.userID(for: account), current != id { logout() }
        hostUserID = id
        guard client != nil else { return nil }
        return Task { await sendUserID() }
    }

    /// Counts the times the server gave this install back its earlier user (`restored`): open screens
    /// reload when it changes.
    private(set) var restores = 0

    /// Labels this install's user with the app's id. The server refuses another id for the same user (409):
    /// then this install belonged to someone else, so start a new one.
    private func sendUserID(retry: Bool = true) async {
        guard let id = hostUserID, let account = keychainAccount else { return }
        do {
            let updated = try await authorized { try await $0.updateProfile(token: $1, name: nil, email: nil, userID: id) }
            profile = updated
            Keychain.setUserID(id, for: account)
            // Back on the same device, same account (spec 03): the old conversations are this install's again.
            if updated.restored == true {
                restores += 1
                await refresh()
            }
        } catch DevReplyError.server(409) where retry {
            logout(keepUserID: true)
            await sendUserID(retry: false)
        } catch {}
    }

    /// `DevReply.logout()`: the server stops accepting this install (and its push token), the device
    /// forgets it, and the next person starts from a new, empty install. Conversations stay for the team.
    func logout(keepUserID: Bool = false) {
        if let client, let account = keychainAccount, let token = Keychain.token(for: account) {
            Task { try? await client.logout(token: token) }
        }
        let id = hostUserID
        forgetInstall()
        if keepUserID { hostUserID = id }
        guard client != nil else { return }
        Task {
            await refresh()
            await PushManager.shared.sendTokenIfNeeded()
        }
    }

    /// `DevReply.deleteUser()`: deletes the user's data on the server and forgets the install. If the server
    /// can't be reached (or answers 5xx/429), the device forgets the user anyway (like `logout`, without
    /// `POST /v1/logout`) and keeps the old token as a pending deletion, retried at every `configure` and
    /// return to the foreground until the server confirms. True = deleted on the server now.
    func deleteUser() async -> Bool {
        guard let client, let account = keychainAccount else { return false }
        var deleted = true
        // No install token: this device never registered, so the server has nothing of it to delete.
        if let token = Keychain.token(for: account) {
            deleted = await Self.deleteOnServer(token: token, client: client)
            if !deleted { Keychain.setPendingDeletions(Keychain.pendingDeletions(for: account) + [token], for: account) }
        }
        forgetInstall()
        Task {
            await refresh()
            await PushManager.shared.sendTokenIfNeeded()
        }
        return deleted
    }

    /// `DELETE /v1/me` with this token. Done on 2xx, and on 401/404 (already gone); anything else
    /// (offline, 5xx, 429…) means try again later.
    nonisolated static func deleteOnServer(token: String, client: APIClient) async -> Bool {
        do {
            try await client.deleteUser(token: token)
            return true
        } catch DevReplyError.unauthenticated, DevReplyError.notFound {
            return true
        } catch {
            return false
        }
    }

    /// Retries each saved deletion with its own saved token (never this install's). Returns the ones
    /// still owed.
    nonisolated static func retryDeletions(_ tokens: [String], client: APIClient) async -> [String] {
        var remaining: [String] = []
        for token in tokens {
            if await !deleteOnServer(token: token, client: client) { remaining.append(token) }
        }
        return remaining
    }

    @ObservationIgnored private var retryingDeletions = false

    func retryPendingDeletions() async {
        guard let client, let account = keychainAccount, !retryingDeletions else { return }
        let tokens = Keychain.pendingDeletions(for: account)
        guard !tokens.isEmpty else { return }
        retryingDeletions = true
        defer { retryingDeletions = false }
        let remaining = Set(await Self.retryDeletions(tokens, client: client))
        let done = Set(tokens).subtracting(remaining)
        // Deletions queued meanwhile stay.
        Keychain.setPendingDeletions(Keychain.pendingDeletions(for: account).filter { !done.contains($0) }, for: account)
    }

    /// Everything this device knew about the user: the token, who they were, their chats on screen.
    private func forgetInstall() {
        if let account = keychainAccount {
            Keychain.deleteToken(for: account)
            Keychain.deleteUserID(for: account)
        }
        registering = nil
        live.stop()
        lastSeenMessage = nil
        appliedLive = []
        hostUserID = nil
        hostUser = nil
        pendingAttributes = [:]
        conversations = []
        profile = nil
        PushManager.shared.forgetSentToken()
        DevReply.closeMessenger()
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
                Task { @MainActor in
                    // The messenger is still open: live again (a fresh start, failures forgotten).
                    Messenger.shared.startLive()
                    await Messenger.shared.retryPendingDeletions()
                    await Messenger.shared.refresh()
                }
            }
        }
        if backgroundObserver == nil {
            // Leaving the app: the socket closes normally (pushes cover the rest).
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in Messenger.shared.live.stop() }
            }
        }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, UIApplication.shared.applicationState == .active, !self.isPresented,
                      !self.conversations.isEmpty else { continue }
                // Switched off in the dashboard: no banners.
                guard self.isAvailable else { continue }
                let before = Dictionary(uniqueKeysWithValues: self.conversations.map { ($0.id, $0.unread) })
                await self.refresh()
                if self.isAvailable, let fresh = self.conversations.first(where: { $0.unread > (before[$0.id] ?? 0) && $0.lastAuthor != "user" }) {
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
