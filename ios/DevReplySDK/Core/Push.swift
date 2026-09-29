import Foundation
import Observation
import UIKit
import UserNotifications

/// Push notifications for replies (spec 05). Never forced:
/// - If the app already has permission (it asked earlier), DevReply only registers for pushes.
/// - If nobody asked yet, the chat offers "Turn on" after the user's first message, then Apple's prompt.
/// - If the user said no, the chat offers "Open Settings". "Not now" hides it for a few days.
/// The device token comes from the host app's `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// via `DevReply.registerPush(_:)`.
@MainActor @Observable
final class PushManager: NSObject {
    static let shared = PushManager()

    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var askSnoozedUntil: Date?
    private var lastSentToken: String?
    private var pendingToken: String?

    static let snooze: TimeInterval = 3 * 24 * 60 * 60

    override init() {
        super.init()
        askSnoozedUntil = Self.readSnooze()
    }

    /// After `configure`: learn the current permission, and if the app already has it, register.
    func start() {
        // Only if the app has no notification delegate: DevReply then handles taps and foreground pushes
        // itself. Otherwise the app's own handling asks DevReply (see NotificationDelegate).
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = NotificationDelegate.shared }
        Task { await refreshStatus(registerIfAllowed: true) }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // Back from Settings, or permission changed elsewhere.
            Task { @MainActor in await PushManager.shared.refreshStatus(registerIfAllowed: true) }
        }
    }

    func refreshStatus(registerIfAllowed: Bool) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        if registerIfAllowed, [.authorized, .provisional, .ephemeral].contains(status) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// The soft ask is showing because of this state (nil = don't show).
    var askState: AskState? {
        if let until = askSnoozedUntil, until > Date() { return nil }
        switch status {
        case .notDetermined: return .firstAsk
        case .denied: return .openSettings
        default: return nil
        }
    }

    enum AskState { case firstAsk, openSettings }

    /// "Turn on": Apple's prompt; if allowed, register for pushes.
    func requestPermission() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus(registerIfAllowed: granted)
    }

    func openSettings() {
        let url = URL(string: UIApplication.openNotificationSettingsURLString) ?? URL(string: UIApplication.openSettingsURLString)!
        UIApplication.shared.open(url)
    }

    func notNow() {
        let until = Date().addingTimeInterval(Self.snooze)
        askSnoozedUntil = until
        Self.writeSnooze(until)
    }

    // MARK: Token

    func register(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingToken = hex
        Task { await sendTokenIfNeeded() }
    }

    /// After a logout the device gets a new install: send the token to it again.
    func forgetSentToken() {
        lastSentToken = nil
    }

    /// Sends the token once the install exists; called again after `configure`.
    func sendTokenIfNeeded() async {
        guard let token = pendingToken, token != lastSentToken else { return }
        let env = Self.pushEnvironment
        let ok = (try? await Messenger.shared.authorized { client, installToken in
            try await client.updatePushToken(token: installToken, pushToken: token, environment: env)
        }) != nil
        if ok { lastSentToken = token }
    }

    /// `sandbox` for builds signed for development (Xcode runs), `production` for TestFlight and the App Store.
    static let pushEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<plist"), let end = text.range(of: "</plist>"),
              let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return "production" } // App Store builds carry no provisioning profile
        return (entitlements["aps-environment"] as? String) == "development" ? "sandbox" : "production"
        #endif
    }()

    // MARK: Snooze, stored as a small file (no UserDefaults: keeps the privacy manifest simple)

    private static var snoozeURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "DevReply/push-ask-snoozed-until")
    }

    private static func readSnooze() -> Date? {
        guard let url = snoozeURL, let text = try? String(contentsOf: url, encoding: .utf8), let t = Double(text) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private static func writeSnooze(_ date: Date) {
        guard let url = snoozeURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Taps and foreground pushes

/// What DevReply does with its own pushes. Used by its default delegate, and by host apps that have
/// their own delegate and forward to `DevReply.presentationOptions` / `handleNotificationResponse`.
@MainActor
enum PushHandling {
    /// The DevReply conversation a notification is about, or nil if it isn't ours. Pushes carry it twice:
    /// `devreply.conversation_id`, and flat as `devreply_conversation_id` (what JavaScript and Dart
    /// libraries pass on as the notification's data).
    nonisolated static func conversationID(in userInfo: [AnyHashable: Any]) -> UUID? {
        if let info = userInfo["devreply"] as? [String: Any], let id = info["conversation_id"] as? String {
            return UUID(uuidString: id)
        }
        return (userInfo["devreply_conversation_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Foreground: DevReply's own banner (unless that conversation is on screen); keep it in the list.
    static func willPresent(conversationID id: UUID, title: String, body: String) -> UNNotificationPresentationOptions {
        Task { await Messenger.shared.refresh() }
        if Messenger.shared.visibleConversation == id { return [] }
        if Messenger.shared.isPresented { return [.list] }
        InAppBanner.shared.show(title: title, body: body, conversationID: id)
        return [.list, .sound]
    }

    /// Tap: open the messenger on that conversation. Before `configure` (a tap that launched a React
    /// Native or Flutter app), it opens once the app configures DevReply.
    static func didReceive(conversationID id: UUID) {
        Messenger.shared.openWhenConfigured(conversationID: id)
    }
}

/// DevReply's notification delegate, only for apps that have none: DevReply never takes the app's
/// notifications over. Apps with their own delegate (or a push library: Firebase Messaging,
/// expo-notifications…) keep it and ask DevReply about each notification: `DevReply.presentationOptions(for:)`,
/// `handleNotificationResponse(_:)`, or `handleNotificationOpened(userInfo:)` from JavaScript and Dart.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let content = notification.request.content
        guard let id = PushHandling.conversationID(in: content.userInfo) else { return [.banner, .list, .sound] }
        let (title, body) = (content.title, content.body)
        return await MainActor.run { PushHandling.willPresent(conversationID: id, title: title, body: body) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = PushHandling.conversationID(in: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushHandling.didReceive(conversationID: id) }
    }
}
