import Foundation

/// What happened in the chat, for your analytics (`DevReply.addEventListener`).
public enum DevReplyEvent: Sendable, Equatable {
    /// The messenger appeared.
    case messengerOpened
    /// The messenger went away, any way (closed, swiped down, switched off).
    case messengerClosed
    /// The user started a conversation (the server accepted its first message). `messageSent` follows.
    case conversationStarted(conversationID: UUID, category: DevReplyCategory?)
    /// The server accepted a message from the user, including a conversation's first one.
    case messageSent(conversationID: UUID)
}

/// A listener added with `DevReply.addEventListener`. Keep it to stop listening with `cancel()`;
/// discarding it keeps the listener for the life of the app.
@MainActor
public final class DevReplySubscription {
    private let id: UUID

    init(id: UUID) { self.id = id }

    /// Stops this listener. Calling it again does nothing.
    public func cancel() {
        Events.remove(id)
    }
}

/// The app's listeners, called on the main actor in the order they were added.
@MainActor
enum Events {
    private static var listeners: [(id: UUID, call: @MainActor (DevReplyEvent) -> Void)] = []

    static func add(_ listener: @escaping @MainActor (DevReplyEvent) -> Void) -> DevReplySubscription {
        let id = UUID()
        listeners.append((id, listener))
        return DevReplySubscription(id: id)
    }

    static func remove(_ id: UUID) {
        listeners.removeAll { $0.id == id }
    }

    static func emit(_ event: DevReplyEvent) {
        // A copy: a listener may cancel itself (or add another) while being called.
        for listener in listeners { listener.call(event) }
    }
}
