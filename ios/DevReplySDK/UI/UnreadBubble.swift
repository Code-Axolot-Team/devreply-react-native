import Observation
import SwiftUI
import UIKit

/// A small round DevReply button over the whole app, bottom right, while a reply is waiting
/// (spec 05). Tap opens that conversation. Nothing for the host app to build: it shows itself.
///
/// - Only while there are unread replies, the messenger is closed and the keyboard is down.
/// - Its own small window (the size of the button), so the rest of the app stays fully usable.
/// - Drag it up or down to move it; swipe it off to the right to hide it until the next reply.
/// - Off with `DevReply.showsUnreadBubble = false` for apps that show `DevReply.unreadCount` themselves.
@MainActor
final class UnreadBubble {
    static let shared = UnreadBubble()

    var isEnabled = true {
        didSet { update() }
    }

    private var window: PassthroughWindow?
    private let model = BubbleModel()
    private var keyboardUp = false
    /// Hidden by a swipe while this many were unread; shows again when more arrive.
    private var dismissedAt: Int?
    /// Distance of the button's bottom edge from the screen's bottom edge; drag changes it.
    private var bottomOffset: CGFloat?
    private var started = false

    static let size: CGFloat = 60
    /// Room around the button for its shadow and badge.
    static let margin: CGFloat = 14

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UnreadBubble.shared.keyboard(up: true) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UnreadBubble.shared.keyboard(up: false) }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UnreadBubble.shared.update() }
        }
        observe()
    }

    /// Re-runs `update` whenever what it reads changes (unread counts, the messenger opening).
    private func observe() {
        withObservationTracking {
            update()
        } onChange: {
            Task { @MainActor in UnreadBubble.shared.observe() }
        }
    }

    private func keyboard(up: Bool) {
        keyboardUp = up
        update()
    }

    private func update() {
        let messenger = Messenger.shared
        let unread = messenger.unreadCount
        if let dismissedAt, unread > dismissedAt { self.dismissedAt = nil }
        if unread == 0 { dismissedAt = nil }
        let shows = isEnabled && unread > 0 && !messenger.isPresented && !keyboardUp && dismissedAt == nil
        model.count = unread
        model.teamName = messenger.config.teamName
        if shows { show() } else { hide() }
    }

    private func show() {
        if window != nil { return }
        guard UIApplication.shared.applicationState != .background,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: BubbleView(model: model, onTap: open, onMove: move, onDismiss: dismiss))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.frame = frame(in: scene)
        window.isHidden = false
        self.window = window
        model.shown = false
        withAnimation(.spring(duration: 0.4, bounce: 0.45)) { model.shown = true }
    }

    private func hide() {
        guard let window else { return }
        self.window = nil
        window.isHidden = true
    }

    private func frame(in scene: UIWindowScene) -> CGRect {
        let screen = scene.screen.bounds
        let insets = scene.windows.first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
        let side = Self.size + Self.margin * 2
        // Default: clear of a tab bar. Kept between the status bar and the home indicator.
        let bottom = bottomOffset ?? (insets.bottom + 72)
        let clamped = min(max(bottom, insets.bottom + 8), screen.height - insets.top - side - 8)
        bottomOffset = clamped
        return CGRect(x: screen.width - side - 4, y: screen.height - clamped - side, width: side, height: side)
    }

    private func open() {
        let id = Messenger.shared.conversations.first(where: { $0.unread > 0 })?.id
        hide()
        DevReply.open(conversationID: id)
    }

    private func move(by dy: CGFloat) {
        guard let window, let scene = window.windowScene else { return }
        bottomOffset = (bottomOffset ?? 0) - dy
        window.frame = frame(in: scene)
    }

    private func dismiss() {
        dismissedAt = Messenger.shared.unreadCount
        hide()
    }
}

@MainActor @Observable
private final class BubbleModel {
    var count = 0
    var teamName = ""
    var shown = false
}

private struct BubbleView: View {
    let model: BubbleModel
    let onTap: () -> Void
    let onMove: (CGFloat) -> Void
    let onDismiss: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        Button(action: onTap) {
            Image("devreply-mark", bundle: .devReply)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .offset(y: 2)
                .frame(width: UnreadBubble.size, height: UnreadBubble.size)
        }
        .buttonStyle(BubblePressStyle())
        .overlay(alignment: .topTrailing) { badge.offset(x: 6, y: -6) }
        .offset(x: max(dragX, 0))
        .opacity(1 - min(max(dragX, 0) / 80, 0.7))
        .scaleEffect(model.shown ? 1 : 0.2)
        .opacity(model.shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Over the button's own tap: a drag moves or hides it, a plain tap still opens the chat.
        .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { value in
                    // The first clear movement decides: sideways hides, up/down moves.
                    if sideways == nil { sideways = abs(value.translation.width) > abs(value.translation.height) }
                    if sideways == true {
                        dragX = value.translation.width
                    } else {
                        onMove(value.translation.height - lastY)
                        lastY = value.translation.height
                    }
                }
                .onEnded { value in
                    // It sits at the edge, so a short swipe (or a flick) to the right is enough.
                    if sideways == true, value.translation.width > 30 || value.predictedEndTranslation.width > 90 {
                        onDismiss()
                    }
                    sideways = nil
                    lastY = 0
                    withAnimation(.snappy) { dragX = 0 }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(t("bubble.open"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityIdentifier("devreply.bubble")
        .onAppear { _ = BrandFont.register }
    }

    @State private var lastY: CGFloat = 0
    @State private var sideways: Bool?

    private var badge: some View {
        Text(model.count > 9 ? "9+" : "\(model.count)")
            .font(.text(13, .bold))
            .monospacedDigit()
            .foregroundStyle(Brand.ink)
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, model.count > 9 ? 3 : 0)
            .background(Brand.pink, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.ink, lineWidth: 2.5))
            .accessibilityHidden(true)
    }

    private var label: String {
        let who = model.teamName.isEmpty ? t("team") : model.teamName
        return model.count == 1 ? t("launcher.one", ["team": who]) : t("launcher.many", ["team": who, "count": "\(model.count)"])
    }
}

/// Lemon circle, ink outline, hard shadow; presses down into the shadow like the brand's buttons.
private struct BubblePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(Circle().fill(Brand.lemon))
            .overlay(Circle().strokeBorder(Brand.ink, lineWidth: 3))
            .background(Circle().fill(Brand.ink).offset(x: pressed ? 1 : 4, y: pressed ? 1 : 4))
            .offset(x: pressed ? 3 : 0, y: pressed ? 3 : 0)
            .animation(.snappy(duration: 0.12), value: pressed)
    }
}
