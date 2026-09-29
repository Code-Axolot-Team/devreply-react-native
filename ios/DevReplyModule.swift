import ExpoModulesCore
import UIKit

// The React Native bridge: every call goes to the native DevReply SDK (compiled into this pod from
// DevReplySDK/, the same sources as the iOS SDK), on the main actor.
public class DevReplyModule: Module {
    private var watching = false
    /// The latest unread count, kept by the observer so JS can read it without waiting on the main thread.
    private let unread = UnreadBox()

    public func definition() -> ModuleDefinition {
        Name("DevReply")
        Events("onUnreadChange")

        Function("configure") { (publicKey: String) in
            Task { @MainActor in
                DevReply.configure(publicKey)
                self.watchUnread()
            }
        }

        Function("present") { (category: String?) in
            Task { @MainActor in
                DevReply.present(category: category.flatMap(DevReplyCategory.init(rawValue:)))
            }
        }

        Function("setUser") { (name: String?, email: String?) in
            Task { @MainActor in DevReply.setUser(name: name, email: email) }
        }

        Function("setAttributes") { (attributes: [String: Any]) in
            var converted: [String: DevReplyAttribute?] = [:]
            for (key, value) in attributes {
                converted[key] = Self.attribute(value)
            }
            let values = converted
            Task { @MainActor in DevReply.setAttributes(values) }
        }

        Function("getUnreadCount") { () -> Int in
            self.unread.value
        }

        Function("setShowsUnreadBubble") { (shows: Bool) in
            Task { @MainActor in DevReply.showsUnreadBubble = shows }
        }

        Function("setLocale") { (tag: String?) in
            Task { @MainActor in DevReply.setLocale(tag) }
        }

        Function("handle") { (url: String) in
            guard let link = URL(string: url) else { return }
            Task { @MainActor in _ = DevReply.handle(link) }
        }

        Function("registerPushToken") { (hex: String) in
            guard let data = Self.data(hex: hex) else { return }
            Task { @MainActor in DevReply.registerPush(data) }
        }
    }

    /// Sends `onUnreadChange` whenever the count changes (Observation, re-armed after each change).
    @MainActor
    private func watchUnread() {
        guard !watching else { return }
        watching = true
        observe(last: -1)
    }

    @MainActor
    private func observe(last: Int) {
        let count = withObservationTracking { DevReply.unreadCount } onChange: { [weak self] in
            Task { @MainActor in self?.observe(last: -2) }
        }
        if count != unread.value || last == -1 {
            unread.value = count
            sendEvent("onUnreadChange", ["count": count])
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
