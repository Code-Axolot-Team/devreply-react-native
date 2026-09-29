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

    // MARK: Signed-in users

    /// After your user signs in: your own id for them (never an email or anything secret). The team sees it
    /// next to the user, and your backend can delete the user by it. If another user was signed in on this
    /// device, DevReply logs them out first, so nobody sees someone else's chats.
    ///
    /// ```swift
    /// DevReply.login(userID: account.id)
    /// DevReply.setUser(name: account.name, email: account.email)
    /// ```
    public static func login(userID: String) {
        Messenger.shared.login(userID: userID)
    }

    /// When your user signs out: DevReply forgets this device's chats, and the next person starts empty.
    /// Their conversations stay with your team. Call it on every sign-out (and account switch).
    public static func logout() {
        Messenger.shared.logout()
    }

    /// When your user deletes their account (Apple requires account deletion in the app): deletes their
    /// name, email, attributes, conversations, messages and files from DevReply, then logs out. Returns
    /// false if DevReply couldn't be reached; try again, or delete from your backend
    /// (`DELETE /v1/project/users?user_id=…` with a secret key).
    @discardableResult
    public static func deleteUser() async -> Bool {
        await Messenger.shared.deleteUser()
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

    /// The chat's language, e.g. `"es"`, `"pt-BR"`, `"ja"` (English, Spanish, Portuguese, French, German,
    /// Italian, Dutch, Polish, Russian, Ukrainian, Turkish, Greek, Japanese, Korean, Chinese). By default
    /// it follows the device; set it if your app has its own language setting. `nil` = follow the device
    /// again. Open screens switch at once, and the team sees the user's language in the inbox.
    ///
    /// ```swift
    /// DevReply.setLocale("es")        // or DevReply.setLocale(nil)
    /// ```
    public static func setLocale(_ identifier: String?) {
        L10n.shared.set(identifier)
    }

    /// What the app set with `setLocale`, or `nil` when the chat follows the device.
    public static var locale: String? { L10n.shared.override }

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
    /// a DevReply notification (the messenger opens on that conversation); false for your own.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        guard let id = PushHandling.conversationID(in: response.notification.request.content.userInfo) else { return false }
        PushHandling.didReceive(conversationID: id)
        return true
    }

    /// A notification the user tapped, as the data a push library passes on (the notification's
    /// `userInfo` or its custom keys): opens that conversation when it's DevReply's, and returns false for
    /// anything else. The React Native and Flutter packages call this from the app's push library.
    @discardableResult
    public static func handleNotificationOpened(userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = PushHandling.conversationID(in: userInfo) else { return false }
        PushHandling.didReceive(conversationID: id)
        return true
    }

    // MARK: Deep links

    /// Opens the conversation from a DevReply link: the "Reply in the app" button in DevReply's emails
    /// opens your app's deep link with `?devreply=<conversation id>` (set the link in DevReply → Settings →
    /// Emails to your users). Pass every URL your app opens; returns `false` for URLs that aren't DevReply's.
    ///
    /// SwiftUI:
    /// ```swift
    /// WindowGroup { ContentView() }
    ///     .onOpenURL { url in if !DevReply.handle(url) { /* your own links */ } }
    /// ```
    /// UIKit (scene delegate):
    /// ```swift
    /// func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    ///     for context in contexts where DevReply.handle(context.url) { return }
    /// }
    /// ```
    /// The messenger opens on that conversation (or its home, if this install doesn't have it), and
    /// DevReply → Settings shows the deep link as working.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard let id = conversationID(inDeepLink: url) else { return false }
        Messenger.shared.reportDeepLinkOpened()
        openWhenReady(conversationID: id, attempts: 10)
        return true
    }

    /// The conversation in a DevReply link (`…?devreply=<uuid>`), if it is one.
    nonisolated static func conversationID(inDeepLink url: URL) -> UUID? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "devreply" }?.value
        return value.flatMap(UUID.init(uuidString:))
    }

    /// At a cold start the app's window may not be up yet when the link arrives: wait for it briefly.
    static func openWhenReady(conversationID: UUID, attempts: Int) {
        if topViewController() != nil || attempts <= 0 {
            open(conversationID: conversationID)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            openWhenReady(conversationID: conversationID, attempts: attempts - 1)
        }
    }

    /// Opens the messenger over the current screen. With a category, it goes straight to a new conversation.
    public static func present(category: DevReplyCategory? = nil) {
        presentMessenger(MessengerView(startCategory: category))
    }

    /// Closes the messenger if it's open (the user logged out).
    static func closeMessenger() {
        if Messenger.shared.isPresented, let top = topViewController(), top is UIHostingController<MessengerView> {
            top.dismiss(animated: true)
        }
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
