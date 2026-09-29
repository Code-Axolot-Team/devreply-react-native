import Foundation
import SwiftUI
import Observation

// The React Native bridge's Swift half: every call goes to the native DevReply SDK (compiled into this pod
// from DevReplySDK/, the same sources as the iOS SDK), on the main actor. DevReplyRN.mm (the TurboModule)
// calls it.
@objc(DevReplyBridge)
public final class DevReplyBridge: NSObject {
    /// Called on the main thread whenever the unread count changes, and once after `configure`.
    @objc public var onUnread: ((Int) -> Void)?
    /// Called on the main thread for what happens in the chat: type, conversation id, category.
    @objc public var onEvent: ((String, String?, String?) -> Void)?
    private var events: DevReplySubscription?
    private var watching = false
    /// The latest unread count, kept by the observer so JS can read it without waiting on the main thread.
    private let unread = UnreadBox()

    @objc public func configure(_ publicKey: String) {
        Task { @MainActor in
            DevReply.configure(publicKey)
            self.watchUnread()
            self.forwardEvents()
        }
    }

    @MainActor
    private func forwardEvents() {
        guard events == nil else { return }
        events = DevReply.addEventListener { [weak self] event in
            switch event {
            case .messengerOpened: self?.onEvent?("messengerOpened", nil, nil)
            case .messengerClosed: self?.onEvent?("messengerClosed", nil, nil)
            case let .conversationStarted(id, category):
                self?.onEvent?("conversationStarted", id.uuidString.lowercased(), category?.rawValue)
            case let .messageSent(id): self?.onEvent?("messageSent", id.uuidString.lowercased(), nil)
            }
        }
    }

    /// Runs on the main actor and returns its result (JavaScript calls come on another thread).
    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    @objc public func login(_ userID: String) {
        Task { @MainActor in DevReply.login(userID: userID) }
    }

    @objc public func logout() {
        Task { @MainActor in DevReply.logout() }
    }

    @objc public func deleteUser(_ done: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in done(await DevReply.deleteUser()) }
    }

    @objc public func present(_ category: String?, message: String?, attributes: [String: Any]) -> Bool {
        var context: [String: DevReplyAttribute] = [:]
        for (key, value) in attributes {
            if let a = Self.attribute(value) { context[key] = a }
        }
        let values = context
        return onMain {
            DevReply.present(category: category.flatMap(DevReplyCategory.init(rawValue:)), message: message, attributes: values)
        }
    }

    @objc public var isAvailable: Bool { onMain { DevReply.isAvailable } }

    /// Colours as hex strings; any left out keep the base theme's (DevReply's light, or its dark).
    /// lightMode: keep | reset | custom; darkMode: keep | off | default | custom.
    @objc public func setTheme(_ lightMode: String, light: [String: Any]?, darkMode: String, dark: [String: Any]?) {
        let lightColors = light, darkColors = dark
        Task { @MainActor in
            switch lightMode {
            case "reset": DevReply.theme = .light
            case "custom": DevReply.theme = Self.theme(lightColors, base: .light)
            default: break
            }
            switch darkMode {
            case "off": DevReply.darkTheme = nil
            case "default": DevReply.darkTheme = .dark
            case "custom": DevReply.darkTheme = Self.theme(darkColors, base: .dark)
            default: break
            }
        }
    }

    private static func theme(_ colors: [String: Any]?, base: DevReplyTheme) -> DevReplyTheme {
        var t = base
        let c = { (key: String) in (colors?[key] as? String).flatMap(Self.color(hex:)) }
        if let v = c("primary") { t.primary = v }
        if let v = c("accent") { t.accent = v }
        if let v = c("userBubble") { t.userBubble = v }
        if let v = c("userBubbleText") { t.userBubbleText = v }
        if let v = c("background") { t.background = v }
        if let v = c("ink") { t.ink = v }
        return t
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    static func color(hex: String) -> Color? {
        let clean = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6 || clean.count == 8, let v = UInt64(clean, radix: 16) else { return nil }
        let rgba = clean.count == 6 ? (v << 8) | 0xFF : v
        return Color(
            .sRGB,
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            opacity: Double(rgba & 0xFF) / 255
        )
    }

    @objc public func setUser(_ name: String?, email: String?) {
        Task { @MainActor in DevReply.setUser(name: name, email: email) }
    }

    @objc public func setAttributes(_ attributes: [String: Any]) {
        var converted: [String: DevReplyAttribute?] = [:]
        for (key, value) in attributes {
            converted[key] = Self.attribute(value)
        }
        let values = converted
        Task { @MainActor in DevReply.setAttributes(values) }
    }

    @objc public var unreadCount: Int { unread.value }

    @objc public func setShowsUnreadBubble(_ shows: Bool) {
        Task { @MainActor in DevReply.showsUnreadBubble = shows }
    }

    @objc public func setLocale(_ tag: String?) {
        Task { @MainActor in DevReply.setLocale(tag) }
    }

    @objc public func handle(_ url: String) {
        guard let link = URL(string: url) else { return }
        Task { @MainActor in _ = DevReply.handle(link) }
    }

    /// A tapped notification's data: opens the conversation when it's DevReply's (after configure, if the
    /// tap launched the app).
    @objc public func handleNotificationOpened(_ data: [String: Any]) -> Bool {
        guard PushHandling.conversationID(in: data) != nil else { return false }
        let userInfo = data
        Task { @MainActor in _ = DevReply.handleNotificationOpened(userInfo: userInfo) }
        return true
    }

    @objc public func registerPushToken(_ hex: String) {
        guard let data = Self.data(hex: hex) else { return }
        Task { @MainActor in DevReply.registerPush(data) }
    }

    /// Reports the count whenever it changes (Observation, re-armed after each change).
    @MainActor
    private func watchUnread() {
        guard !watching else { return }
        watching = true
        observe(first: true)
    }

    @MainActor
    private func observe(first: Bool) {
        let count = withObservationTracking { DevReply.unreadCount } onChange: { [weak self] in
            Task { @MainActor in self?.observe(first: false) }
        }
        if count != unread.value || first {
            unread.value = count
            onUnread?(count)
        }
    }

    private static func attribute(_ value: Any) -> DevReplyAttribute? {
        // JS true/false arrive as NSNumber too: tell them apart by their CF type.
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        }
        if let s = value as? String { return .string(s) }
        return nil
    }

    private static func data(hex: String) -> Data? {
        let clean = hex.filter(\.isHexDigit)
        guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// A number shared between the main actor (writer) and the JS thread (reader).
private final class UnreadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
