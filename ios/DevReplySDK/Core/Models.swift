import Foundation

/// Version of this SDK. Sent on install registration and compared with each block's `min_sdk`.
public let devReplySDKVersion = "0.5.0"

/// What a conversation is about. Set by the start button the user picked (spec 05).
public enum DevReplyCategory: String, Codable, Sendable, CaseIterable {
    case bug, billing, idea, question, other

    /// Categories added on the server later decode as `.other`, so old SDKs keep working.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DevReplyCategory(rawValue: raw) ?? .other
    }
}

// Forward compatibility (spec 05): a newer server must never break an SDK already shipped in apps.
// Rules for every model here: unknown enum values map to a safe default, optional or newer fields
// are decoded with defaults, and one bad item in a list is skipped instead of failing the list.

/// Decodes an array, dropping elements that fail to decode.
struct Lossy<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.items = items
    }

    private struct Skip: Decodable {}
}

/// Who replied, as users see it (spec 05, 0.4): a teammate's or a shared persona.
struct Persona: Codable, Sendable, Equatable, Hashable {
    let name: String
    let title: String
    let avatarUrl: URL?

    private enum Keys: String, CodingKey { case name, title, avatarUrl }

    init(name: String, title: String = "", avatarUrl: URL? = nil) {
        self.name = name
        self.title = title
        self.avatarUrl = avatarUrl
    }

    /// Only the name is needed; a blank one makes the persona absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "persona without a name"))
        }
        self.name = name
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        avatarUrl = ((try? c.decodeIfPresent(String.self, forKey: .avatarUrl)) ?? nil).flatMap(URL.init(string:))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(avatarUrl?.absoluteString, forKey: .avatarUrl)
    }
}

struct MessengerConfig: Codable, Sendable, Equatable {
    struct StartButton: Codable, Sendable, Equatable, Identifiable {
        let category: DevReplyCategory
        let emoji: String
        let title: String
        var id: DevReplyCategory { category }
    }

    let appName: String
    let teamName: String
    let greeting: String
    let intro: String
    let replyTime: String
    /// What goes after "Please allow up to": "3 working days", "an hour". Set per app in the dashboard.
    let replyWithin: String
    let startButtons: [StartButton]
    /// The app's icon (Settings → General). Shown in the header; initials when missing.
    let appIconUrl: URL?
    /// Teammates with photos, most recent repliers first (up to 3): the faces on the home screen.
    let team: [Persona]
    /// Texts that are still DevReply's defaults (`greeting`, `intro`, `start_buttons`, …): shown in the
    /// chat's language. Anything the team wrote is shown as written.
    /// `nil` when the server doesn't send the list (before it had it): then texts equal to DevReply's
    /// English defaults count as defaults.
    let localize: [String]?
    /// The reply time as a key (`3_working_days`): the chat says it in the user's language.
    let replyWithinKey: String?
    /// False when the team switched the chat off in the dashboard (0.4.4): `DevReply.isAvailable`.
    /// Missing (older servers) = on.
    let enabled: Bool

    private enum Keys: String, CodingKey {
        case appName, teamName, greeting, intro, replyTime, replyWithin, startButtons, appIconUrl, team, localize, replyWithinKey
        case enabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(appName, forKey: .appName)
        try c.encode(teamName, forKey: .teamName)
        try c.encode(greeting, forKey: .greeting)
        try c.encode(intro, forKey: .intro)
        try c.encode(replyTime, forKey: .replyTime)
        try c.encode(replyWithin, forKey: .replyWithin)
        try c.encode(startButtons, forKey: .startButtons)
        try c.encodeIfPresent(appIconUrl?.absoluteString, forKey: .appIconUrl)
        try c.encode(team, forKey: .team)
        try c.encodeIfPresent(localize, forKey: .localize)
        try c.encodeIfPresent(replyWithinKey, forKey: .replyWithinKey)
        try c.encode(enabled, forKey: .enabled)
    }

    init(
        appName: String, teamName: String, greeting: String, intro: String, replyTime: String, replyWithin: String,
        startButtons: [StartButton], appIconUrl: URL? = nil, team: [Persona] = [],
        localize: [String]? = nil, replyWithinKey: String? = nil, enabled: Bool = true
    ) {
        self.appName = appName
        self.teamName = teamName
        self.greeting = greeting
        self.intro = intro
        self.replyTime = replyTime
        self.replyWithin = replyWithin
        self.startButtons = startButtons
        self.appIconUrl = appIconUrl
        self.team = team
        self.localize = localize
        self.replyWithinKey = replyWithinKey
        self.enabled = enabled
    }

    /// Every field is optional on the wire; missing ones fall back to the placeholder.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = MessengerConfig.placeholder
        let string = { (key: Keys) in (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        appName = string(.appName) ?? d.appName
        teamName = string(.teamName) ?? appName
        greeting = string(.greeting) ?? d.greeting
        intro = string(.intro) ?? d.intro
        replyTime = string(.replyTime) ?? d.replyTime
        replyWithin = string(.replyWithin) ?? d.replyWithin
        startButtons = ((try? c.decodeIfPresent(Lossy<StartButton>.self, forKey: .startButtons)) ?? nil)?.items ?? d.startButtons
        appIconUrl = string(.appIconUrl).flatMap(URL.init(string:))
        team = Array((((try? c.decodeIfPresent(Lossy<Persona>.self, forKey: .team)) ?? nil)?.items ?? []).prefix(3))
        localize = ((try? c.decodeIfPresent(Lossy<String>.self, forKey: .localize)) ?? nil)?.items
        replyWithinKey = string(.replyWithinKey) ?? Self.presetKey(forEnglish: replyWithin)
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
    }

    /// The preset behind an English reply time ("3 working days" → `3_working_days`), for servers that
    /// send only the English words.
    static func presetKey(forEnglish text: String) -> String? {
        let presets = ["an hour": "hour", "a few hours": "hours", "a day": "day", "2 days": "2_days",
                       "3 working days": "3_working_days", "a week": "week"]
        return presets[text.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Whether `field` is still DevReply's default (then it's shown in the user's language).
    private func isDefault(_ field: String, _ value: String, englishKey: String) -> Bool {
        if let localize { return localize.contains(field) }
        return value == DevReplyStrings.table("en")[englishKey]
    }

    // What the chat shows: DevReply's defaults in the user's language, the team's own texts as written.

    var greetingText: String { isDefault("greeting", greeting, englishKey: "greeting") ? t("greeting") : greeting }
    var introText: String { isDefault("intro", intro, englishKey: "intro") ? t("intro") : intro }

    func title(for button: StartButton) -> String {
        if button.title.isEmpty { return button.category.defaultTitle }
        return isDefault("start_buttons", button.title, englishKey: "category.\(button.category.rawValue)")
            ? button.category.defaultTitle : button.title
    }

    /// "Usually replies within 3 working days", in the user's language.
    var replyTimeText: String {
        if let key = replyWithinKey, L10n.has("reply_time.\(key)") { return t("reply_time.\(key)") }
        return replyTime
    }

    /// "Please allow up to 3 working days for a reply.", in the user's language.
    var replyAllowText: String {
        if let key = replyWithinKey, L10n.has("reply_allow.\(key)") { return t("reply_allow.\(key)") }
        return "Please allow up to \(replyWithin) for a reply."
    }

    /// Same as the server's defaults, so the first open looks final before the config arrives
    /// (no layout jump). The team name starts as the host app's display name.
    static let placeholder: MessengerConfig = {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
        return MessengerConfig(
            appName: name,
            teamName: name,
            greeting: "Hi there 👋",
            intro: "Ask us anything, or tell us what's broken.",
            replyTime: "Usually replies within 3 working days",
            replyWithin: "3 working days",
            startButtons: [.bug, .billing, .idea, .question].map {
                StartButton(category: $0, emoji: "", title: "")
            },
            // Before the config arrives, everything is DevReply's default: in the user's language.
            localize: ["greeting", "intro", "start_buttons", "reply_time", "reply_within"],
            replyWithinKey: "3_working_days"
        )
    }()
}

struct Conversation: Decodable, Sendable, Identifiable, Equatable, Hashable {
    let id: UUID
    let status: String
    let category: DevReplyCategory?
    let lastText: String?
    let lastAuthor: String?
    let unread: Int
    let lastMessageAt: Date

    private enum Keys: String, CodingKey {
        case id, status, category, lastText, lastAuthor, unread, lastMessageAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        lastMessageAt = try c.decode(Date.self, forKey: .lastMessageAt)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil ?? "open"
        category = (try? c.decodeIfPresent(DevReplyCategory.self, forKey: .category)) ?? nil
        lastText = (try? c.decodeIfPresent(String.self, forKey: .lastText)) ?? nil
        lastAuthor = (try? c.decodeIfPresent(String.self, forKey: .lastAuthor)) ?? nil
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? nil ?? 0
    }

    init(
        id: UUID, status: String, category: DevReplyCategory?, lastText: String?, lastAuthor: String?, unread: Int,
        lastMessageAt: Date
    ) {
        self.id = id
        self.status = status
        self.category = category
        self.lastText = lastText
        self.lastAuthor = lastAuthor
        self.unread = unread
        self.lastMessageAt = lastMessageAt
    }

    /// The list entry after a live message (what the next `GET /v1/conversations` would say). A message not
    /// newer than the entry changes nothing (the list already has it). `onScreen`: the user sees it, so a
    /// team reply doesn't count as unread.
    func receiving(_ message: Message, onScreen: Bool) -> Conversation {
        guard message.createdAt > lastMessageAt else { return self }
        let counts = !onScreen && !message.isFromUser
        return Conversation(
            id: id, status: status, category: category, lastText: message.plainText,
            lastAuthor: message.author.rawValue, unread: counts ? unread + 1 : unread, lastMessageAt: message.createdAt
        )
    }
}

struct Message: Decodable, Sendable, Identifiable, Equatable {
    enum Author: String, Decodable, Sendable {
        case user, admin, agent, system

        /// Authors added later (e.g. a bot) show as the team, never as the user.
        init(from decoder: Decoder) throws {
            self = Author(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
        }
    }

    let id: UUID
    let author: Author
    let blocks: [Block]
    let createdAt: Date
    /// Who replied (team messages from SDK 0.4 servers). Missing or malformed = none.
    let persona: Persona?
    /// A user message that answered a button question (0.5.0): which question, which option. Read from the
    /// message or from any of its blocks, wherever the server puts it.
    let answer: ButtonAnswer?

    private enum Keys: String, CodingKey {
        case id, author, blocks, createdAt, persona, answer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        author = (try? c.decode(Author.self, forKey: .author)) ?? .system
        blocks = ((try? c.decodeIfPresent(Lossy<Block>.self, forKey: .blocks)) ?? nil)?.items ?? []
        persona = (try? c.decodeIfPresent(Persona.self, forKey: .persona)) ?? nil
        answer = ((try? c.decodeIfPresent(ButtonAnswer.self, forKey: .answer)) ?? nil)
            ?? ((try? c.decodeIfPresent(Lossy<BlockAnswer>.self, forKey: .blocks)) ?? nil)?.items.lazy.compactMap(\.answer).first
    }

    /// Only the `answer` of a block, if it has one.
    private struct BlockAnswer: Decodable, Sendable {
        let answer: ButtonAnswer?
        private enum Keys: String, CodingKey { case answer }
        init(from decoder: Decoder) throws {
            answer = ((try? decoder.container(keyedBy: Keys.self).decodeIfPresent(ButtonAnswer.self, forKey: .answer)) ?? nil)
        }
    }

    var isFromUser: Bool { author == .user }
    /// All blocks as plain text: what the list preview and older renderers show.
    var plainText: String { blocks.map(\.plainText).joined(separator: "\n") }
}

/// A typed message block (spec 05). Unknown types, and types newer than this SDK, fall back to
/// plain text instead of failing to decode, so old SDKs never break.
enum Block: Decodable, Sendable, Equatable {
    case text(String)
    /// A line the server wrote in English that the chat translates (e.g. "✓ Marked as resolved…").
    case localized(key: String, fallback: String)
    case image(url: URL, width: Int?, height: Int?)
    case file(url: URL, name: String, size: Int?, mime: String?)
    /// A team or agent reply in DevReply Markdown (0.5.0), parsed; `plain` is its plain text (previews, copy).
    case markdown([MarkdownBlock], plain: String)
    /// A question with answers as buttons (0.5.0): the question in Markdown, 2 to 5 options. `answered` is
    /// the chosen option's id when the server already says so on the block itself.
    case buttons(question: [MarkdownBlock], plain: String, options: [ButtonOption], answered: String?)
    case unsupported(fallback: String)

    private enum Keys: String, CodingKey {
        case type, text, fallback, minSdk, url, width, height, name, size, mime, key, options, answer
    }

    /// The server's resolved line, before it had a key.
    static let legacyResolvedText = "✓ Marked as resolved. Reply here any time to open it again."

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        let fallback = (try? c.decode(String.self, forKey: .fallback)) ?? t("unsupported")
        if let minSdk = try? c.decode(String.self, forKey: .minSdk),
           Self.isVersion(devReplySDKVersion, olderThan: minSdk) {
            self = .unsupported(fallback: fallback)
            return
        }
        switch type {
        case "text":
            let text = (try? c.decode(String.self, forKey: .text)) ?? fallback
            let key = try? c.decode(String.self, forKey: .key)
            if key == "resolved" || text == Self.legacyResolvedText {
                self = .localized(key: "system.resolved", fallback: text)
            } else {
                self = .text(text)
            }
        case "markdown":
            // The server sends min_sdk 0.5.0 (handled above): older SDKs show `fallback`, the plain text.
            if let text = try? c.decode(String.self, forKey: .text) {
                let blocks = Markdown.parse(text)
                self = .markdown(blocks, plain: Markdown.plain(blocks))
            } else {
                self = .unsupported(fallback: fallback)
            }
        case "buttons":
            // min_sdk 0.5.0 (handled above): older SDKs show `fallback`, the question and numbered options.
            let options = ((try? c.decode(Lossy<ButtonOption>.self, forKey: .options))?.items ?? [])
            if let text = try? c.decode(String.self, forKey: .text), !options.isEmpty {
                let blocks = Markdown.parse(text)
                let answered = (try? c.decode(OptionAnswer.self, forKey: .answer))?.optionId
                self = .buttons(question: blocks, plain: Markdown.plain(blocks), options: options,
                                answered: answered.flatMap { id in options.contains { $0.id == id } ? id : nil })
            } else {
                self = .unsupported(fallback: fallback)
            }
        case "image":
            if let url = try? c.decode(URL.self, forKey: .url) {
                self = .image(url: url, width: try? c.decode(Int.self, forKey: .width), height: try? c.decode(Int.self, forKey: .height))
            } else {
                self = .unsupported(fallback: t("photo"))
            }
        case "file":
            if let url = try? c.decode(URL.self, forKey: .url) {
                self = .file(
                    url: url,
                    name: (try? c.decode(String.self, forKey: .name)) ?? t("file"),
                    size: try? c.decode(Int.self, forKey: .size),
                    mime: try? c.decode(String.self, forKey: .mime)
                )
            } else {
                self = .unsupported(fallback: fallback)
            }
        default:
            self = .unsupported(fallback: fallback)
        }
    }

    var plainText: String {
        switch self {
        case .text(let s): s
        case .localized(let key, let fallback): L10n.has(key) ? t(key) : fallback
        case .image: t("photo")
        case .file(_, let name, _, _): name
        case .markdown(_, let plain): plain
        case .buttons(_, let plain, _, _): plain
        case .unsupported(let fallback): fallback
        }
    }

    static func isVersion(_ a: String, olderThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// One answer of a button question: the server's id and what the button says.
struct ButtonOption: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let label: String

    private enum Keys: String, CodingKey { case id, label }

    /// Both needed, the label not blank; an option without them is left out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id: String
        if let text = try? c.decode(String.self, forKey: .id) { id = text } else { id = String(try c.decode(Int.self, forKey: .id)) }
        let label = try c.decode(String.self, forKey: .label)
        guard !id.isEmpty, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "option without id or label"))
        }
        self.id = id
        self.label = label
    }

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// `answer` on a buttons block: only the option matters there.
private struct OptionAnswer: Decodable {
    let optionId: String
}

/// Which button question a user message answers, and with which option (`POST …/messages` `answer`).
struct ButtonAnswer: Codable, Sendable, Equatable, Hashable {
    let messageId: UUID
    let optionId: String

    init(messageId: UUID, optionId: String) {
        self.messageId = messageId
        self.optionId = optionId
    }

    private enum Keys: String, CodingKey {
        // Decoded with `convertFromSnakeCase` (API responses); encoded as the server spells it.
        case messageId, optionId
        case messageIdWire = "message_id", optionIdWire = "option_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        messageId = try (try? c.decode(UUID.self, forKey: .messageId)) ?? c.decode(UUID.self, forKey: .messageIdWire)
        optionId = try (try? c.decode(String.self, forKey: .optionId)) ?? c.decode(String.self, forKey: .optionIdWire)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(messageId.uuidString.lowercased(), forKey: .messageIdWire)
        try c.encode(optionId, forKey: .optionIdWire)
    }
}

struct MessagesPage: Decodable, Sendable {
    let conversation: Conversation
    let messages: [Message]

    private enum Keys: String, CodingKey { case conversation, messages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conversation = try c.decode(Conversation.self, forKey: .conversation)
        messages = try c.decode(Lossy<Message>.self, forKey: .messages).items
    }
}

struct StartedConversation: Decodable, Sendable {
    let conversation: Conversation
    let message: Message
}

/// A custom attribute value: text, number or true/false. Shown to the team next to the user.
public enum DevReplyAttribute: Sendable, Equatable, Encodable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n) where n.rounded() == n && abs(n) < 1e15: try c.encode(Int64(n))
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        }
    }
}

extension DevReplyAttribute {
    /// A conversation's context (`DevReply.present(attributes:)`) as the server accepts it: at most 20
    /// values, names of 1–40 letters, digits, `_ - .` or space, text up to 500 characters, finite numbers.
    /// Anything else is left out (with a note in the console) so the conversation itself never fails.
    static func context(_ attributes: [String: DevReplyAttribute]) -> [String: DevReplyAttribute] {
        var out: [String: DevReplyAttribute] = [:]
        for key in attributes.keys.sorted() {
            guard let value = attributes[key] else { continue }
            let validKey = (1...40).contains(key.count)
                && key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-. ".unicodeScalars.contains($0)) }
            guard validKey else {
                print("DevReply: context \"\(key)\" left out: names are 1–40 letters, digits, _ - . or space.")
                continue
            }
            guard out.count < 20 else {
                print("DevReply: context \"\(key)\" left out: at most 20 values.")
                continue
            }
            switch value {
            case .number(let n) where !n.isFinite:
                print("DevReply: context \"\(key)\" left out: not a finite number.")
            case .string(let text) where text.count > 500:
                out[key] = .string(String(text.prefix(500)))
            default:
                out[key] = value
            }
        }
        return out
    }
}

/// What the end user told us about themselves (Intercom-style contact details).
struct Profile: Decodable, Sendable, Equatable {
    var name: String?
    var email: String?
    /// `PATCH /v1/me {user_id}` (0.5.0): this device's earlier user with that id got the install back, with
    /// their old conversations (spec 03, "Same device after logout"). Reload the list.
    var restored: Bool?
}

/// A photo or file ready to upload.
struct OutgoingAttachment: Sendable, Equatable {
    let kind: String
    let mime: String
    let data: Data
    let filename: String?
    let width: Int?
    let height: Int?
}

struct UploadSlot: Decodable, Sendable {
    let id: UUID
    let uploadUrl: URL
    let uploadHeaders: [String: String]
}

struct RegisteredInstall: Decodable, Sendable {
    let installId: UUID
    let token: String
}
