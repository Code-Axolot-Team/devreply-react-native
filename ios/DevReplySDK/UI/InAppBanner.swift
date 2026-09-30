import SwiftUI
import UIKit

/// A DevReply-style banner at the top of the screen when a reply arrives while the app is open and the
/// messenger is closed. Tap opens the conversation; it goes away after a few seconds or with a swipe up.
/// Shown in its own window above the app, so it works over any screen without touching the host's views.
@MainActor
final class InAppBanner {
    static let shared = InAppBanner()

    private var window: UIWindow?
    private var hideTask: Task<Void, Never>?

    func show(title: String, body: String, conversationID: UUID?) {
        // Switched off in the dashboard: no banners.
        guard Messenger.shared.isAvailable else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        hide(animated: false)

        let window = PassthroughWindow(windowScene: scene)
        // Just the strip under the status bar where the banner sits.
        let top = scene.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 54
        window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: top + 140)
        window.windowLevel = .statusBar + 1
        // Light or dark like the app's own window (its `overrideUserInterfaceStyle` too), for the dark theme.
        window.overrideUserInterfaceStyle = PassthroughWindow.appStyle(in: scene)
        window.backgroundColor = .clear
        let view = BannerView(title: title, text: body) { [weak self] in
            self?.hide(animated: false)
            DevReply.open(conversationID: conversationID)
        } onDismiss: { [weak self] in
            self?.hide(animated: true)
        }
        let host = UIHostingController(
            rootView: view.environment(\.layoutDirection, L10n.shared.isRTL ? .rightToLeft : .leftToRight)
        )
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        UIAccessibility.post(notification: .announcement, argument: "\(title): \(body)")

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        guard let window else { return }
        self.window = nil
        if animated {
            UIView.animate(withDuration: 0.2, animations: { window.alpha = 0 }, completion: { _ in window.isHidden = true })
        } else {
            window.isHidden = true
        }
    }
}

/// DevReply's banner window: only as tall as the banner strip at the top, so the rest of the app stays
/// fully usable. Never the key window, so the app keeps keyboard focus and the messenger is presented
/// on the app's own window.
final class PassthroughWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    /// The app's own window's appearance override, so DevReply's windows match it.
    static func appStyle(in scene: UIWindowScene) -> UIUserInterfaceStyle {
        let app = scene.windows.first { !($0 is PassthroughWindow) && $0.isKeyWindow }
            ?? scene.windows.first { !($0 is PassthroughWindow) }
        return app?.overrideUserInterfaceStyle ?? .unspecified
    }
}

private struct BannerView: View {
    let title: String
    let text: String
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var shown = false
    @State private var drag: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack {
            if shown {
                Button(action: onTap) {
                    HStack(alignment: .top, spacing: 12) {
                        TeamAvatar(name: title, size: 40, imageURL: Messenger.shared.config.appIconUrl)
                        VStack(alignment: .leading, spacing: 3) {
                            Kicker(text: title.isEmpty ? t("banner.new_reply") : title, inverted: true)
                            Text(text)
                                .font(.text(15, .medium))
                                .foregroundStyle(Palette.active.onCard)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BrutalPressStyle(fill: Palette.active.card, shadow: 5))
                .accessibilityIdentifier("devreply.banner")
                .accessibilityHint(t("banner.opens"))
                .padding(.horizontal, 12)
                .offset(y: min(drag, 0))
                .gesture(DragGesture().onChanged { drag = $0.translation.height }.onEnded { value in
                    if value.translation.height < -30 { onDismiss() } else { withAnimation(.snappy) { drag = 0 } }
                })
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 8)
        .environment(\.devReplyLine, Palette.lineScale(colorScheme))
        .onAppear {
            _ = BrandFont.register
            withAnimation(.spring(duration: 0.35)) { shown = true }
        }
    }
}
