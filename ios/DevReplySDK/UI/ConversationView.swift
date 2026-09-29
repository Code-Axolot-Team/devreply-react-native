import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Attachments the user picked

/// A photo or file picked by the user, ready to upload. Photos are resized and re-encoded
/// (which drops EXIF, including location); files go as they are, up to 10 MB.
struct Staged: Identifiable, Equatable {
    let id = UUID()
    let attachment: OutgoingAttachment
    /// Photos only: the thumbnail.
    let preview: UIImage?

    static let maxPhotoSide: CGFloat = 2048
    static let maxFileBytes = 10 * 1024 * 1024

    var name: String { attachment.filename ?? "Photo" }

    static func photo(_ data: Data) -> Staged? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPhotoSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
        let attachment = OutgoingAttachment(
            kind: "image", mime: "image/jpeg", data: jpeg, filename: nil, width: Int(size.width), height: Int(size.height)
        )
        return Staged(attachment: attachment, preview: resized)
    }

    /// A file from the Files picker.
    static func file(at url: URL) -> Result<Staged, FileProblem> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard data.count <= maxFileBytes else { return .failure(.tooBig(url.lastPathComponent)) }
        let type = UTType(filenameExtension: url.pathExtension)
        // Images picked as files still go as photos (resized, shown inline).
        if type?.conforms(to: .image) == true, let photo = photo(data) { return .success(photo) }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let attachment = OutgoingAttachment(
            kind: "file", mime: mime, data: data, filename: url.lastPathComponent, width: nil, height: nil
        )
        return .success(Staged(attachment: attachment, preview: nil))
    }

    enum FileProblem: Error {
        case unreadable, tooBig(String)
    }
}

// MARK: - Model

/// One conversation. Starts empty for a new one; the first send creates it on the server.
@MainActor @Observable
final class ConversationModel {
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let attachments: [Staged]
        var failure: String?
    }

    let category: DevReplyCategory?
    private(set) var conversation: Conversation?
    private(set) var messages: [Message] = []
    private(set) var pending: [Pending] = []
    private(set) var sentCount = 0

    init(existing: Conversation?, category: DevReplyCategory?) {
        conversation = existing
        self.category = existing?.category ?? category
    }

    func load() async {
        guard let id = conversation?.id else { return }
        guard let page = try? await Messenger.shared.authorized({ try await $0.messages(token: $1, conversation: id) }) else {
            return
        }
        conversation = page.conversation
        if page.messages != messages { messages = page.messages }
        Messenger.shared.upsert(page.conversation)
    }

    func send(_ raw: String, attachments: [Staged]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let item = Pending(text: text, attachments: attachments)
        pending.append(item)
        sentCount += 1
        enqueue(item)
    }

    func retry(_ item: Pending) {
        guard let index = pending.firstIndex(of: item) else { return }
        pending[index].failure = nil
        enqueue(pending[index])
    }

    /// Sends go out one at a time, in the order typed: two in flight could reach the server swapped.
    private var queue: Task<Void, Never>?

    private func enqueue(_ item: Pending) {
        let previous = queue
        queue = Task {
            await previous?.value
            await deliver(item)
        }
    }

    private func deliver(_ item: Pending) async {
        let category = category
        do {
            var ids: [UUID] = []
            for staged in item.attachments {
                let attachment = staged.attachment
                ids.append(try await Messenger.shared.authorized { try await $0.upload(token: $1, attachment: attachment) })
            }
            let attachmentIDs = ids
            if let id = conversation?.id {
                let message = try await Messenger.shared.authorized {
                    try await $0.sendMessage(token: $1, conversation: id, text: item.text, attachments: attachmentIDs)
                }
                messages.append(message)
            } else {
                let started = try await Messenger.shared.authorized {
                    try await $0.startConversation(token: $1, category: category, text: item.text, attachments: attachmentIDs)
                }
                conversation = started.conversation
                messages.append(started.message)
                Messenger.shared.upsert(started.conversation)
            }
            pending.removeAll { $0.id == item.id }
        } catch {
            let reason = switch error as? DevReplyError {
            case .unavailable: "Attachments can't be sent right now. Tap to retry."
            case .network: "You're offline. Tap to retry."
            case .invalid(let message): "Not sent: \(message). Tap to retry."
            default: "Not sent. Tap to retry."
            }
            if let index = pending.firstIndex(where: { $0.id == item.id }) { pending[index].failure = reason }
        }
    }
}

// MARK: - Screen

struct ConversationView: View {
    @State private var model: ConversationModel
    @State private var draft = ""
    @State private var staged: [Staged] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var pickError: String?
    @State private var viewing: ViewedImage?
    @State private var previewFile: URL?
    @FocusState private var composerFocused: Bool
    /// Started on this screen (not opened from the list): the email ask belongs to its first message only.
    @State private var startedHere: Bool
    @State private var emailAskDone = false
    private var messenger: Messenger { Messenger.shared }
    private var config: MessengerConfig { messenger.config }
    private var theme: DevReplyTheme { DevReplyTheme.current }

    init(existing: Conversation) {
        _model = State(initialValue: ConversationModel(existing: existing, category: nil))
        _startedHere = State(initialValue: false)
    }

    init(newIn category: DevReplyCategory?) {
        _model = State(initialValue: ConversationModel(existing: nil, category: category))
        _startedHere = State(initialValue: true)
    }

    private var hasEmail: Bool { !(messenger.profile?.email ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// Right after the first message of a new request, if we have no email: optional, asked once.
    private var showsEmailAsk: Bool {
        startedHere && !emailAskDone && messenger.profile != nil && !hasEmail
            && model.messages.contains(where: \.isFromUser)
    }

    var body: some View {
        // One container (not a Group, which copies its modifiers onto each branch): the composer stays
        // the same view when the first message arrives, so it keeps focus and the keyboard stays up.
        ZStack {
            if items.isEmpty {
                ScrollView { intro }
            } else {
                // Inverted list: the scroll view is flipped and so is every row, so the bottom is the
                // natural start. New messages and time labels always appear at the bottom and push the
                // rest up; nothing ever scrolls in code.
                ScrollView {
                    LazyVStack(spacing: 10) {
                        Color.clear.frame(height: 4)
                        ForEach(Array(items.reversed().enumerated()), id: \.element.id) { position, item in
                            row(item)
                                .flippedVertically()
                                // VoiceOver reads oldest first, like the screen.
                                .accessibilitySortPriority(Double(position))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .animation(.snappy(duration: 0.25), value: items.count)
                }
                .flippedVertically()
                .scrollIndicators(.hidden)
                .withoutScrollEdgeEffect()
            }
        }
        // Drag down to hide the keyboard, like any chat. While it's up, the sheet itself doesn't swipe
        // closed, so the drag always goes to the keyboard (in a short chat the sheet would take it).
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(composerFocused)
        .background(theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if messenger.profile == nil {
                Color.clear.frame(height: 1)
            } else if messenger.needsName {
                NameForm()
            } else {
                VStack(spacing: 0) {
                    // One card at a time: the email ask first, then notifications.
                    if showsEmailAsk {
                        EmailAskCard { withAnimation(.snappy) { emailAskDone = true } }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if model.messages.contains(where: \.isFromUser), let ask = PushManager.shared.askState {
                        PushAskCard(state: ask, teamName: config.teamName)
                    }
                    composer
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.primary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    TeamAvatar(name: config.teamName, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.teamName.isEmpty ? "Chat" : config.teamName)
                            .font(.display(16, relativeTo: .headline))
                            .foregroundStyle(theme.ink)
                        if !config.replyTime.isEmpty {
                            Text(config.replyTime)
                                .font(.text(11, .medium, relativeTo: .caption2))
                                .foregroundStyle(theme.ink.opacity(0.75))
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.sentCount)
        .task(id: model.conversation?.id) {
            await messenger.loadProfileIfNeeded()
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        .fullScreenCover(item: $viewing) { ImageViewer(image: $0) }
        .quickLookPreview($previewFile)
        .onAppear {
            if model.conversation == nil && !messenger.needsName { composerFocused = true }
            messenger.visibleConversation = model.conversation?.id
        }
        .onDisappear { messenger.visibleConversation = nil }
        .onChange(of: model.conversation?.id) { _, id in messenger.visibleConversation = id }
    }

    // MARK: Rows

    /// Everything the thread shows, oldest first: time labels, messages, sends in progress.
    private enum ChatItem: Identifiable {
        case time(Date, id: String)
        case message(Message)
        case pending(ConversationModel.Pending)
        /// Under the user's first message: we got it, please allow up to <reply time>.
        case notice

        var id: String {
            switch self {
            case .time(_, let id): "time-\(id)"
            case .notice: "notice"
            case .message(let m): m.id.uuidString
            case .pending(let p): "pending-\(p.id.uuidString)"
            }
        }
    }

    private var items: [ChatItem] {
        var out: [ChatItem] = []
        let firstFromUser = model.messages.firstIndex(where: \.isFromUser)
        for (index, message) in model.messages.enumerated() {
            if showsTime(at: index) { out.append(.time(message.createdAt, id: message.id.uuidString)) }
            out.append(.message(message))
            if index == firstFromUser { out.append(.notice) }
        }
        out += model.pending.map { .pending($0) }
        return out
    }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item {
        case .time(let date, _):
            TimeLabel(date: date)
        case .message(let message):
            MessageView(message: message, teamName: config.teamName, onOpenImage: { viewing = $0 }, onOpenFile: open)
        case .pending(let pending):
            PendingView(item: pending, teamName: config.teamName)
                .onTapGesture { if pending.failure != nil { model.retry(pending) } }
        case .notice:
            ReceivedNotice(teamName: config.teamName, within: config.replyWithin, email: hasEmail ? messenger.profile?.email : nil)
        }
    }

    // MARK: Empty state

    /// Shown while the conversation is empty, at the top of the screen.
    private var intro: some View {
        let category = model.category ?? .other
        let title = config.startButtons.first { $0.category == category }?.title ?? category.defaultTitle
        return VStack(spacing: 16) {
            category.icon
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .padding(18)
                .brutal(fill: .white, shadow: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.display(26, relativeTo: .title))
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
            Text(category.prompt)
                .font(.text(16, .medium))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 36)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !staged.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(staged) { item in
                            StagedThumb(item: item) { staged.removeAll { $0.id == item.id } }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 2)
                }
            }
            if let pickError {
                Text(pickError).font(.text(13, .bold)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 46, height: 46)
                        .brutal(fill: .white, shadow: 3)
                }
                .accessibilityLabel("Attach a photo or file")
                .accessibilityIdentifier("devreply.attach")

                TextField("Message…", text: $draft, axis: .vertical)
                    .font(.text(17))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 46)
                    .background(.white)
                    .overlay(Rectangle().strokeBorder(theme.ink, lineWidth: 3))
                    .accessibilityIdentifier("devreply.composer")

                Button {
                    model.send(draft, attachments: staged)
                    draft = ""
                    staged = []
                    photoItems = []
                    pickError = nil
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 19, weight: .black))
                        .foregroundStyle(theme.ink)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(BrutalPressStyle(fill: theme.accent, shadow: 3))
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.45)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("devreply.send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white)
        .overlay(alignment: .top) { Rectangle().fill(theme.ink).frame(height: 3) }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let photo = Staged.photo(data) {
                staged.append(photo)
            }
        }
        staged = Array(staged.suffix(4))
        photoItems = []
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        pickError = nil
        for url in urls {
            switch Staged.file(at: url) {
            case .success(let item): staged.append(item)
            case .failure(.tooBig(let name)): pickError = "\(name) is over 10 MB."
            case .failure(.unreadable): pickError = "Couldn't read that file."
            }
        }
        if staged.count > 4 {
            staged = Array(staged.prefix(4))
            pickError = "Up to 4 attachments per message."
        }
    }

    /// Files open in Quick Look (native preview) after a download to a temporary folder.
    private func open(_ file: RemoteFile) {
        Task {
            if let local = await FileCache.shared.localCopy(of: file) { previewFile = local }
        }
    }

    private func showsTime(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return model.messages[index].createdAt.timeIntervalSince(model.messages[index - 1].createdAt) > 15 * 60
    }
}

// MARK: - Name first (spec 05)

/// Asked once, before the first message, unless the host app passed a name with `DevReply.setUser`.
private struct NameForm: View {
    @State private var name = ""
    @State private var email = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var field: Field?

    enum Field { case name, email }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker(text: "Before we start", inverted: true)
            Text("So the developer knows who they're talking to. Add your email to get the reply there too.")
                .font(.text(15, .medium))
                .foregroundStyle(Brand.ink)
            input("Your name", text: $name, field: .name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .onSubmit { field = .email }
                .accessibilityIdentifier("devreply.profile.name")
            input("Email (optional)", text: $email, field: .email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityIdentifier("devreply.profile.email")
            if let error {
                Text(error).font(.text(13, .bold)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
            }
            Button(action: save) {
                Text(saving ? "Saving…" : "Start chatting")
                    .font(.text(16, .bold))
                    .foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(BrutalPressStyle(fill: Brand.pink, shadow: 4))
            .disabled(saving || trimmed(name).isEmpty)
            .opacity(trimmed(name).isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("devreply.profile.save")
        }
        .padding(16)
        .background(Brand.lemon)
        .overlay(alignment: .top) { Rectangle().fill(Brand.ink).frame(height: 3) }
        .onAppear { field = .name }
    }

    private func input(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .font(.text(17))
            .foregroundStyle(Brand.ink)
            .tint(Brand.ink)
            .focused($field, equals: field)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.white)
            .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2.5))
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed(name).isEmpty, !saving else { return }
        saving = true
        error = nil
        let email = trimmed(email)
        Task {
            do {
                try await Messenger.shared.saveProfile(name: trimmed(name), email: email.isEmpty ? nil : email)
            } catch DevReplyError.invalid(let message) {
                error = message.prefix(1).uppercased() + message.dropFirst() + "."
            } catch {
                self.error = "Couldn't save. Check your connection and try again."
            }
            saving = false
        }
    }
}

// MARK: - Messages

/// "MON · 18:52", like the timestamps on devreply.com.
private struct TimeLabel: View {
    let date: Date

    var body: some View {
        Kicker(text: date.formatted(.dateTime.weekday(.abbreviated)) + " · " + date.formatted(date: .omitted, time: .shortened))
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
    }
}

struct RemoteFile: Equatable {
    let url: URL
    let name: String
}

private struct MessageView: View {
    let message: Message
    let teamName: String
    let onOpenImage: (ViewedImage) -> Void
    let onOpenFile: (RemoteFile) -> Void

    var body: some View {
        if message.author == .system {
            // e.g. "✓ Marked as resolved…": a quiet line, not a bubble.
            Text(message.plainText)
                .font(.text(13, .bold, relativeTo: .footnote))
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            bubbles
        }
    }

    private var bubbles: some View {
        Row(fromUser: message.isFromUser, teamName: teamName) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    TextBubble(text: text, fromUser: message.isFromUser)
                case .image(let url, let width, let height):
                    RemoteImage(url: url, width: width, height: height)
                        .onTapGesture { onOpenImage(ViewedImage(url: url)) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Photo")
                case .file(let url, let name, let size, _):
                    Button { onOpenFile(RemoteFile(url: url, name: name)) } label: {
                        FileChip(name: name, size: size)
                    }
                    .buttonStyle(BrutalPressStyle(shadow: 3))
                    .accessibilityLabel("File \(name)")
                case .unsupported(let fallback):
                    TextBubble(text: fallback, fromUser: message.isFromUser, muted: true)
                }
            }
        }
    }
}

private struct PendingView: View {
    let item: ConversationModel.Pending
    let teamName: String

    var body: some View {
        Row(fromUser: true, teamName: teamName) {
            ForEach(item.attachments) { staged in
                if let preview = staged.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .aspectRatio(preview.size.width / max(preview.size.height, 1), contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 260)
                        .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 3))
                        .opacity(0.7)
                } else {
                    FileChip(name: staged.name, size: staged.attachment.data.count).brutal(shadow: 3).opacity(0.7)
                }
            }
            if !item.text.isEmpty {
                TextBubble(text: item.text, fromUser: true).opacity(item.failure == nil ? 0.7 : 1)
            }
            if let failure = item.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.text(12, .bold, relativeTo: .caption))
                    .foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
                    .multilineTextAlignment(.trailing)
            } else {
                Kicker(text: item.attachments.isEmpty ? "Sending…" : "Uploading…")
            }
        }
    }
}

/// Lays out one message: the user's on the right, the team's on the left with the avatar.
private struct Row<Content: View>: View {
    let fromUser: Bool
    let teamName: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if fromUser { Spacer(minLength: 48) } else { TeamAvatar(name: teamName, size: 30, fill: Brand.lemon) }
            VStack(alignment: fromUser ? .trailing : .leading, spacing: 6) { content }
            if !fromUser { Spacer(minLength: 48) }
        }
    }
}

private struct TextBubble: View {
    let text: String
    let fromUser: Bool
    var muted = false

    var body: some View {
        let theme = DevReplyTheme.current
        Text(text)
            .font(.text(17, .medium))
            .foregroundStyle(fromUser ? theme.userBubbleText : (muted ? Brand.muted : theme.ink))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .textSelection(.enabled)
            .modifier(BubbleShape(fromUser: fromUser))
    }
}

private struct BubbleShape: ViewModifier {
    let fromUser: Bool

    func body(content: Content) -> some View {
        let theme = DevReplyTheme.current
        if fromUser {
            // Like the blue bubble on devreply.com: flat colour, rounded.
            content.background(theme.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content.brutal(fill: .white, shadow: 3, lineWidth: 2.5, cornerRadius: 14)
        }
    }
}

/// A file in a message: document icon, name, size.
private struct FileChip: View {
    let name: String
    let size: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Brand.ink)
                .frame(width: 40, height: 44)
                .background(Brand.lemon)
                .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.text(15, .bold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.text(12, .medium))
                        .foregroundStyle(Brand.muted)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 240, alignment: .leading)
    }
}

private struct StagedThumb: View {
    let item: Staged
    let remove: () -> Void

    var body: some View {
        Group {
            if let preview = item.preview {
                Image(uiImage: preview).resizable().scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "doc.fill").font(.system(size: 18, weight: .bold))
                    Text(item.name).font(.text(10, .bold)).lineLimit(2).multilineTextAlignment(.center)
                }
                .foregroundStyle(Brand.ink)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.lemon)
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2.5))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Brand.ink)
                    .frame(width: 22, height: 22)
                    .background(Brand.pink)
                    .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2))
            }
            .offset(x: 7, y: -7)
            .accessibilityLabel("Remove \(item.name)")
        }
    }
}

// MARK: - Images and files

struct ViewedImage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Loads an attachment once per URL and keeps it in memory, so polling doesn't reload it.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Downloads a file once into a temporary folder under its own name, for Quick Look.
@MainActor
final class FileCache {
    static let shared = FileCache()
    private var local: [URL: URL] = [:]

    func localCopy(of file: RemoteFile) async -> URL? {
        if let hit = local[file.url], FileManager.default.fileExists(atPath: hit.path) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: file.url) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "devreply-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = file.name.replacingOccurrences(of: "/", with: "_")
        let target = dir.appending(path: safeName.isEmpty ? "file" : safeName)
        guard (try? data.write(to: target)) != nil else { return nil }
        local[file.url] = target
        return target
    }
}

private struct RemoteImage: View {
    let url: URL
    let width: Int?
    let height: Int?
    @State private var image: UIImage?

    var body: some View {
        let ratio = CGFloat(width ?? 4) / CGFloat(max(height ?? 3, 1))
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(ratio, contentMode: .fill)
            } else {
                Brand.grey.overlay(ProgressView().tint(Brand.ink))
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: 220, maxHeight: 260)
        .clipped()
        .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 3))
        .background(Rectangle().fill(Brand.ink).offset(x: 4, y: 4))
        .task(id: url) { image = await ImageCache.shared.image(for: url) }
    }
}

private struct ImageViewer: View {
    let image: ViewedImage
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: UIImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Brand.ink.ignoresSafeArea()
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnifyGesture().onChanged { zoom = max(1, $0.magnification) }.onEnded { _ in
                        withAnimation(.snappy) { zoom = 1 }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Photo")
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            IconButton(systemName: "xmark", label: "Close", fill: Brand.lemon) { dismiss() }
                .padding(20)
        }
        .task { loaded = await ImageCache.shared.image(for: image.url) }
    }
}

private extension View {
    /// iOS 26 blurs content under bars at a scroll view's edges. On a flipped scroll view that blur
    /// lands on the messages, so the inverted list turns it off. Xcode 16 hosts don't have the API.
    @ViewBuilder func withoutScrollEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Upside down. Applied to a scroll view and again to each of its rows, it makes an inverted list.
    func flippedVertically() -> some View {
        scaleEffect(x: 1, y: -1, anchor: .center)
    }
}

// MARK: - After the first message (spec 05)

/// Under the user's first message, so it never feels like writing into the void: it arrived, and how
/// long a reply usually takes (the app's own reply time, from the dashboard). Never promises who answers.
private struct ReceivedNotice: View {
    let teamName: String
    let within: String
    let email: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TeamAvatar(name: teamName, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Thanks, we got it!")
                    .font(.text(15, .bold))
                    .foregroundStyle(Brand.ink)
                Text("Please allow up to \(within) for a reply. " + (email.map { "We'll also email you at \($0)." }
                    ?? "You'll see it right here."))
                    .font(.text(14, .medium))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .brutal(fill: .white, shadow: 3)
        .padding(.top, 4)
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("devreply.notice")
    }
}

/// Right after the first message of a request, if we don't have their email: optional, one tap to skip.
private struct EmailAskCard: View {
    let onDone: () -> Void
    @State private var email = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Get the reply by email too?")
                    .font(.text(15, .bold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                Button("No thanks", action: onDone)
                    .font(.text(14, .bold))
                    .foregroundStyle(Brand.muted)
                    .accessibilityIdentifier("devreply.emailask.skip")
            }
            Text("Optional. Only about this conversation, and you can unsubscribe any time.")
                .font(.text(13, .medium))
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Verbatim: as a string key, SwiftUI would render the address as a blue link.
                TextField("Email", text: $email, prompt: Text(verbatim: "you@example.com"))
                    .font(.text(17))
                    .foregroundStyle(Brand.ink)
                    .tint(Brand.ink)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(.white)
                    .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2.5))
                    .accessibilityIdentifier("devreply.emailask.field")
                Button(action: save) {
                    Text(saving ? "…" : "Save")
                        .font(.text(15, .bold))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                }
                .buttonStyle(BrutalPressStyle(fill: Brand.pink, shadow: 3))
                .disabled(saving || trimmed.isEmpty)
                .opacity(trimmed.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("devreply.emailask.save")
            }
            if let error {
                Text(error).font(.text(13, .bold)).foregroundStyle(Color(red: 0.7, green: 0.15, blue: 0.12))
            }
        }
        .padding(12)
        .background(Brand.lemon)
        .overlay(alignment: .top) { Rectangle().fill(Brand.ink).frame(height: 3) }
    }

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        error = nil
        Task {
            do {
                try await Messenger.shared.saveProfile(name: nil, email: trimmed)
                onDone()
            } catch DevReplyError.invalid(let message) {
                error = message.prefix(1).uppercased() + message.dropFirst() + "."
            } catch {
                self.error = "Couldn't save. Check your connection and try again."
            }
            saving = false
        }
    }
}

// MARK: - Notifications, asked kindly (spec 05)

/// After the first message: "Turn on" (then Apple's prompt), or "Open Settings" if they said no before.
/// Never forced; "Not now" hides it for a few days.
private struct PushAskCard: View {
    let state: PushManager.AskState
    let teamName: String
    @State private var asking = false

    var body: some View {
        let who = teamName.isEmpty ? "the developer" : teamName
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state == .firstAsk ? "bell.badge.fill" : "bell.slash.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Brand.ink)
                .frame(width: 40, height: 40)
                .background(.white)
                .overlay(Rectangle().strokeBorder(Brand.ink, lineWidth: 2))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(state == .firstAsk ? "Don't miss the reply" : "Notifications are off")
                    .font(.text(15, .bold))
                    .foregroundStyle(Brand.ink)
                Text(state == .firstAsk
                    ? "Turn on notifications and you'll know the moment \(who) answers."
                    : "Turn them on in Settings so you see when \(who) answers.")
                    .font(.text(14, .medium))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        if state == .firstAsk {
                            asking = true
                            Task {
                                await PushManager.shared.requestPermission()
                                asking = false
                            }
                        } else {
                            PushManager.shared.openSettings()
                        }
                    } label: {
                        Text(state == .firstAsk ? (asking ? "…" : "Turn on") : "Open Settings")
                            .font(.text(15, .bold))
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                    }
                    .buttonStyle(BrutalPressStyle(fill: Brand.pink, shadow: 3))
                    .accessibilityIdentifier("devreply.push.enable")
                    Button("Not now") { withAnimation { PushManager.shared.notNow() } }
                        .font(.text(14, .bold))
                        .foregroundStyle(Brand.muted)
                        .frame(height: 40)
                        .accessibilityIdentifier("devreply.push.notnow")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Brand.lemon)
        .overlay(alignment: .top) { Rectangle().fill(Brand.ink).frame(height: 3) }
    }
}
