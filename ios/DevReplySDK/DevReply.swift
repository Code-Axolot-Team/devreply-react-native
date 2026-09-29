import SwiftUI
import UIKit
import UserNotifications

/// DevReply: a native chat between your app's users and you (spec 05).
///
/// ```swift
/// DevReply.configure("pk_…")          // once, at launch
/// DevReply.present()                  // from any button
/// ```
@MainActor
public enum DevReply {
    /// The production API. Override only for local development.
    public static let defaultAPIURL = URL(string: "https://api.devreply.com")!

    /// Call once at launch with the app's public key. It is safe to ship inside the app.
    public static func configure(_ publicKey: String, apiURL: URL = defaultAPIURL) {
        Messenger.shared.configure(publicKey: publicKey, apiURL: apiURL)
    }

    /// Tells DevReply who the user is, if your app knows. With a name set, the chat doesn't ask for one.
    /// Call it after `configure`, e.g. after sign-in.
    public static func setUser(name: String?, email: String? = nil) {
        Messenger.shared.setUser(name: name, email: email)
    }

    /// Custom attributes the team sees next to the user (plan, locale, deck count…). `nil` removes one.
    /// Text, number or true/false; up to 50 per user.
    ///
    /// ```swift
    /// DevReply.setAttributes(["plan": "pro", "decks": 12, "trial": false])
    /// ```
    public static func setAttributes(_ attributes: [String: DevReplyAttribute?]) {
        Messenger.shared.setAttributes(attributes)
    }

    /// Colours and look of the messenger. Set before presenting.
    public static var theme: DevReplyTheme {
        get { DevReplyTheme.current }
        set { DevReplyTheme.current = newValue }
    }

    /// Unread replies from the team. Observable: SwiftUI views that read it update on their own.
    public static var unreadCount: Int { Messenger.shared.unreadCount }

    /// While a reply is waiting, a small round DevReply button floats over the app (bottom right) and
    /// opens it. On by default; turn it off if your app shows `unreadCount` in its own UI.
    public static var showsUnreadBubble: Bool {
        get { UnreadBubble.shared.isEnabled }
        set { UnreadBubble.shared.isEnabled = newValue }
    }

    // MARK: Push notifications

    /// Pass the APNs device token from your app delegate:
    /// ```swift
    /// func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    ///     DevReply.registerPush(token)
    /// }
    /// ```
    /// DevReply never forces the permission prompt. If your app already has permission, it just registers;
    /// otherwise the chat offers it after the user's first message.
    public static func registerPush(_ deviceToken: Data) {
        PushManager.shared.register(deviceToken: deviceToken)
    }

    /// If your app has its own `UNUserNotificationCenterDelegate`, forward foreground notifications:
    /// return this when non-nil (it's a DevReply reply), else your own options.
    public static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        let content = notification.request.content
        guard let id = PushHandling.conversationID(in: content.userInfo) else { return nil }
        return PushHandling.willPresent(conversationID: id, title: content.title, body: content.body)
    }

    /// If your app has its own `UNUserNotificationCenterDelegate`, forward taps. Returns true when it was
    /// a DevReply notification (the messenger opens on that conversation).
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        guard let id = PushHandling.conversationID(in: response.notification.request.content.userInfo) else { return false }
        PushHandling.didReceive(conversationID: id)
        return true
    }

    /// Opens the messenger over the current screen. With a category, it goes straight to a new conversation.
    public static func present(category: DevReplyCategory? = nil) {
        presentMessenger(MessengerView(startCategory: category))
    }

    /// Opens the messenger on one conversation (from a push or the in-app banner).
    static func open(conversationID: UUID?) {
        if Messenger.shared.isPresented, let top = topViewController(), top is UIHostingController<MessengerView> {
            top.dismiss(animated: false)
        }
        presentMessenger(MessengerView(openConversation: conversationID))
    }

    private static func presentMessenger(_ view: MessengerView) {
        // The chat is opening: a banner about a reply would only sit on top of it.
        InAppBanner.shared.hide(animated: false)
        guard let top = topViewController() else { return }
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.prefersGrabberVisible = true
        top.present(host, animated: true)
    }

    /// Fetches unread replies, e.g. when the app returns to the foreground.
    public static func refresh() async {
        await Messenger.shared.refresh()
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // The app's own window: never DevReply's banner overlay.
        let windows = scene?.windows.filter { !($0 is PassthroughWindow) && !$0.isHidden } ?? []
        var top = (windows.first { $0.isKeyWindow } ?? windows.first { $0.windowLevel == .normal })?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

public extension View {
    /// Presents the DevReply messenger as a sheet, the SwiftUI way.
    func devReplyMessenger(isPresented: Binding<Bool>, category: DevReplyCategory? = nil) -> some View {
        sheet(isPresented: isPresented) {
            MessengerView(startCategory: category)
                .presentationDragIndicator(.visible)
        }
    }
}
