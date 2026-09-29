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
        // Dates, relative times and system controls in the chat's language (DevReply.setLocale).
        .environment(\.locale, L10n.shared.locale)
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
                    Text(t("powered"))
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
                TeamAvatar(name: messenger.config.teamName, size: 44, imageURL: messenger.config.appIconUrl)
                Kicker(text: messenger.config.teamName.isEmpty ? t("team") : messenger.config.teamName, inverted: true)
                    .lineLimit(1)
                Spacer(minLength: 8)
                IconButton(systemName: "xmark", label: t("close")) { dismiss() }
            }
            Text(messenger.config.greetingText)
                .font(.display(38, relativeTo: .largeTitle))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(messenger.config.introText)
                .font(.text(17, .medium))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !messenger.config.replyTime.isEmpty || !messenger.config.team.isEmpty {
                HStack(spacing: 12) {
                    if !messenger.config.team.isEmpty { teamFaces }
                    if !messenger.config.replyTime.isEmpty {
                        HStack(spacing: 8) {
                            Rectangle().fill(Brand.online).frame(width: 10, height: 10)
                                .overlay(Rectangle().strokeBorder(theme.ink, lineWidth: 1.5))
                            Text(messenger.config.replyTimeText)
                                .font(.text(14, .bold, relativeTo: .footnote))
                                .foregroundStyle(theme.ink)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .brutal(fill: .white, shadow: 3, lineWidth: 2.5)
                    }
                }
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

    /// Who answers here: up to three teammates' faces, overlapping.
    private var teamFaces: some View {
        let team = messenger.config.team
        return HStack(spacing: -10) {
            ForEach(Array(team.enumerated()), id: \.offset) { index, persona in
                PersonaFace(persona: persona, size: 36)
                    .zIndex(Double(team.count - index))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(t("team") + ": " + team.map(\.name).joined(separator: ", "))
        .accessibilityIdentifier("devreply.team")
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("start_title"))
                .font(.display(22, relativeTo: .title2))
                .foregroundStyle(theme.ink)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(messenger.config.startButtons) { button in
                    NavigationLink(value: Route.new(button.category)) {
                        StartTile(button: button, title: messenger.config.title(for: button))
                    }
                    .buttonStyle(BrutalPressStyle())
                    .accessibilityIdentifier("devreply.start.\(button.category.rawValue)")
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("your_conversations"))
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
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            button.category.icon
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
            Text(title)
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

    /// The last message; the server's resolved line in the chat's language.
    static func preview(_ text: String?) -> String {
        guard let text else { return t("photo") }
        return text == Block.legacyResolvedText ? t("system.resolved") : text
    }

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
                    Kicker(text: conversation.lastAuthor == "user" ? t("you") : t("team"))
                    if conversation.status == "closed" {
                        Text(t("resolved"))
                            .font(.text(11, .bold, relativeTo: .caption2))
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.81, green: 0.95, blue: 0.89))
                            .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 1.5))
                    }
                    Spacer()
                    Text(conversation.lastMessageAt.formatted(.relative(presentation: .named).locale(L10n.shared.locale)))
                        .font(.text(12, .medium, relativeTo: .caption))
                        .foregroundStyle(Brand.muted)
                }
                Text(Self.preview(conversation.lastText))
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
                    .accessibilityLabel(t("a11y.unread", ["count": "\(conversation.unread)"]))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(conversation.status == "closed" ? 0.7 : 1)
    }
}

/// The team's avatar: initials on a square, ink outline.
/// The team's avatar: the app icon when the team uploaded one, else initials on a square.
struct TeamAvatar: View {
    let name: String
    let size: CGFloat
    var fill: Color = .white
    var imageURL: URL? = nil

    var body: some View {
        SquareFace(name: name, imageURL: imageURL, size: size, fill: fill, lineWidth: 2.5, fallback: "DR")
    }
}

/// A persona's face: their photo, or initials on white, in a square with an ink border (spec 05, 0.4).
struct PersonaFace: View {
    let persona: Persona
    var size: CGFloat = 22

    var body: some View {
        SquareFace(name: persona.name, imageURL: persona.avatarUrl, size: size, fill: .white, lineWidth: 2, fallback: "?")
    }
}

/// A square photo from the API (app icon, persona photo), with initials while it loads or if it fails.
struct SquareFace: View {
    let name: String
    let imageURL: URL?
    let size: CGFloat
    let fill: Color
    let lineWidth: CGFloat
    let fallback: String

    var body: some View {
        ZStack {
            initials
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: lineWidth))
        .accessibilityHidden(true)
    }

    private var initials: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return Text(letters.isEmpty ? fallback : letters.uppercased())
            .font(.display(size * 0.4, relativeTo: .body))
            .foregroundStyle(Brand.ink)
            .frame(width: size, height: size)
            .background(fill)
    }
}

struct ErrorNote: View {
    let error: DevReplyError
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message).font(.text(15, .medium)).foregroundStyle(Brand.ink)
            Button(action: retry) {
                Text(t("try_again"))
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
        case .network: t("error.offline")
        case .invalidPublicKey: t("error.key")
        default: t("error.generic")
        }
    }
}
