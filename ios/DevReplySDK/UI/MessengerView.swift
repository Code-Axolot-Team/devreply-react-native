import SwiftUI

enum Route: Hashable {
    case conversation(Conversation)
    case new(DevReplyCategory?)
}

/// The messenger: home (greeting, start buttons, past conversations) → one conversation.
struct MessengerView: View {
    let startCategory: DevReplyCategory?
    let openConversation: UUID?
    @State private var path: [Route]

    init(startCategory: DevReplyCategory? = nil) {
        self.startCategory = startCategory
        openConversation = nil
        _path = State(initialValue: startCategory.map { [.new($0)] } ?? [])
        _ = BrandFont.register
    }

    /// Straight into one conversation (from a push or the banner).
    init(openConversation: UUID?) {
        startCategory = nil
        self.openConversation = openConversation
        _path = State(initialValue: [])
        _ = BrandFont.register
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .conversation(let c): ConversationView(existing: c)
                    case .new(let category): ConversationView(newIn: category)
                    }
                }
        }
        .tint(DevReplyTheme.current.ink)
        .onAppear { Messenger.shared.isPresented = true }
        .onDisappear { Messenger.shared.isPresented = false }
        .task {
            guard let id = openConversation else { return }
            if !Messenger.shared.conversations.contains(where: { $0.id == id }) { await Messenger.shared.refresh() }
            if let c = Messenger.shared.conversations.first(where: { $0.id == id }) { path = [.conversation(c)] }
        }
        // The brand is a light look; keep text fields and sheets consistent in dark mode too.
        .environment(\.colorScheme, .light)
    }
}

struct HomeView: View {
    @Environment(\.dismiss) private var dismiss
    private var messenger: Messenger { Messenger.shared }
    private var theme: DevReplyTheme { DevReplyTheme.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 28) {
                    startSection
                    if !messenger.conversations.isEmpty { recentSection }
                    if let error = messenger.lastError, messenger.conversations.isEmpty {
                        ErrorNote(error: error) { Task { await messenger.refresh() } }
                    }
                    Text("Powered by DevReply")
                        .font(.text(12, .medium, relativeTo: .caption))
                        .foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 32)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await messenger.refresh() }
        .task {
            while !Task.isCancelled {
                await messenger.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TeamAvatar(name: messenger.config.teamName, size: 44)
                Kicker(text: messenger.config.teamName.isEmpty ? "Support" : messenger.config.teamName, inverted: true)
                    .lineLimit(1)
                Spacer(minLength: 8)
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
            Text(messenger.config.greeting)
                .font(.display(38, relativeTo: .largeTitle))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(messenger.config.intro)
                .font(.text(17, .medium))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !messenger.config.replyTime.isEmpty {
                HStack(spacing: 8) {
                    Rectangle().fill(Brand.online).frame(width: 10, height: 10)
                        .overlay(Rectangle().strokeBorder(theme.ink, lineWidth: 1.5))
                    Text(messenger.config.replyTime)
                        .font(.text(14, .bold, relativeTo: .footnote))
                        .foregroundStyle(theme.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .brutal(fill: .white, shadow: 3, lineWidth: 2.5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Extends upwards so pulling down shows lemon, not a gap.
        .background(theme.primary.padding(.top, -600))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.ink).frame(height: 3) }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start a conversation")
                .font(.display(22, relativeTo: .title2))
                .foregroundStyle(theme.ink)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(messenger.config.startButtons) { button in
                    NavigationLink(value: Route.new(button.category)) {
                        StartTile(button: button)
                    }
                    .buttonStyle(BrutalPressStyle())
                    .accessibilityIdentifier("devreply.start.\(button.category.rawValue)")
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your conversations")
                .font(.display(22, relativeTo: .title2))
                .foregroundStyle(theme.ink)
            // Open ones first, resolved below.
            ForEach(messenger.conversations.sorted { ($0.status == "closed" ? 1 : 0) < ($1.status == "closed" ? 1 : 0) }.prefix(20)) { conversation in
                NavigationLink(value: Route.conversation(conversation)) {
                    ConversationRow(conversation: conversation)
                }
                .buttonStyle(BrutalPressStyle(shadow: 4))
            }
        }
    }
}

private struct StartTile: View {
    let button: MessengerConfig.StartButton

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            button.category.icon
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
            Text(button.title)
                .font(.text(16, .bold, relativeTo: .subheadline))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .padding(14)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        let category = conversation.category ?? .other
        HStack(alignment: .top, spacing: 12) {
            category.icon
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Kicker(text: conversation.lastAuthor == "user" ? "You" : "Team")
                    if conversation.status == "closed" {
                        Text("✓ Resolved")
                            .font(.text(11, .bold, relativeTo: .caption2))
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.81, green: 0.95, blue: 0.89))
                            .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 1.5))
                    }
                    Spacer()
                    Text(conversation.lastMessageAt, format: .relative(presentation: .named))
                        .font(.text(12, .medium, relativeTo: .caption))
                        .foregroundStyle(Brand.muted)
                }
                Text(conversation.lastText ?? "Photo")
                    .font(.text(15, conversation.unread > 0 ? .bold : .regular, relativeTo: .subheadline))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if conversation.unread > 0 {
                Text("\(conversation.unread)")
                    .font(.text(13, .bold, relativeTo: .caption))
                    .foregroundStyle(Brand.ink)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Brand.pink)
                    .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2))
                    .accessibilityLabel("\(conversation.unread) unread")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(conversation.status == "closed" ? 0.7 : 1)
    }
}

/// The team's avatar: initials on a square, ink outline.
struct TeamAvatar: View {
    let name: String
    let size: CGFloat
    var fill: Color = .white

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.isEmpty ? "DR" : initials.uppercased())
            .font(.display(size * 0.4, relativeTo: .body))
            .foregroundStyle(Brand.ink)
            .frame(width: size, height: size)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2.5))
            .accessibilityHidden(true)
    }
}

struct ErrorNote: View {
    let error: DevReplyError
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message).font(.text(15, .medium)).foregroundStyle(Brand.ink)
            Button(action: retry) {
                Text("Try again")
                    .font(.text(15, .bold))
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(BrutalPressStyle(fill: Brand.pink, shadow: 4))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutal(fill: .white, shadow: 0)
    }

    private var message: String {
        switch error {
        case .network: "You seem to be offline."
        case .invalidPublicKey: "This app's DevReply key isn't valid."
        default: "Something went wrong."
        }
    }
}
