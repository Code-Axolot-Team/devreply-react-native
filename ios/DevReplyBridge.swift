import Foundation
import Observation

// The React Native bridge's Swift half: every call goes to the native DevReply SDK (compiled into this pod
// from DevReplySDK/, the same sources as the iOS SDK), on the main actor. DevReplyRN.mm (the TurboModule)
// calls it.
@objc(DevReplyBridge)
public final class DevReplyBridge: NSObject {
    /// Called on the main thread whenever the unread count changes, and once after `configure`.
    @objc public var onUnread: ((Int) -> Void)?
    private var watching = false
    /// The latest unread count, kept by the observer so JS can read it without waiting on the main thread.
    private let unread = UnreadBox()

    @objc public func configure(_ publicKey: String) {
        Task { @MainActor in
            DevReply.configure(publicKey)
            self.watchUnread()
        }
    }

    @objc public func present(_ category: String?) {
        Task { @MainActor in
            DevReply.present(category: category.flatMap(DevReplyCategory.init(rawValue:)))
        }
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
