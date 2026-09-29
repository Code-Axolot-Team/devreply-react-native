import Foundation

/// Version of this SDK. Sent on install registration and compared with each block's `min_sdk`.
public let devReplySDKVersion = "0.3.2"

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

    private enum Keys: String, CodingKey {
        case appName, teamName, greeting, intro, replyTime, replyWithin, startButtons
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
    }

    init(
        appName: String, teamName: String, greeting: String, intro: String, replyTime: String, replyWithin: String,
        startButtons: [StartButton]
    ) {
        self.appName = appName
        self.teamName = teamName
        self.greeting = greeting
        self.intro = intro
        self.replyTime = replyTime
        self.replyWithin = replyWithin
        self.startButtons = startButtons
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
                StartButton(category: $0, emoji: "", title: $0.defaultTitle)
            }
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

    private enum Keys: String, CodingKey {
        case id, author, blocks, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        author = (try? c.decode(Author.self, forKey: .author)) ?? .system
        blocks = ((try? c.decodeIfPresent(Lossy<Block>.self, forKey: .blocks)) ?? nil)?.items ?? []
    }

    var isFromUser: Bool { author == .user }
    /// All blocks as plain text: what the list preview and older renderers show.
    var plainText: String { blocks.map(\.plainText).joined(separator: "\n") }
}

/// A typed message block (spec 05). Unknown types, and types newer than this SDK, fall back to
/// plain text instead of failing to decode, so old SDKs never break.
enum Block: Decodable, Sendable, Equatable {
    case text(String)
    case image(url: URL, width: Int?, height: Int?)
    case file(url: URL, name: String, size: Int?, mime: String?)
    case unsupported(fallback: String)

    private enum Keys: String, CodingKey {
        case type, text, fallback, minSdk, url, width, height, name, size, mime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        let fallback = (try? c.decode(String.self, forKey: .fallback)) ?? "This message needs a newer version of the app."
        if let minSdk = try? c.decode(String.self, forKey: .minSdk),
           Self.isVersion(devReplySDKVersion, olderThan: minSdk) {
            self = .unsupported(fallback: fallback)
            return
        }
        switch type {
        case "text":
            self = .text((try? c.decode(String.self, forKey: .text)) ?? fallback)
        case "image":
            if let url = try? c.decode(URL.self, forKey: .url) {
                self = .image(url: url, width: try? c.decode(Int.self, forKey: .width), height: try? c.decode(Int.self, forKey: .height))
            } else {
                self = .unsupported(fallback: "Photo")
            }
        case "file":
            if let url = try? c.decode(URL.self, forKey: .url) {
                self = .file(
                    url: url,
                    name: (try? c.decode(String.self, forKey: .name)) ?? "File",
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
        case .image: "Photo"
        case .file(_, let name, _, _): name
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

/// What the end user told us about themselves (Intercom-style contact details).
struct Profile: Decodable, Sendable, Equatable {
    var name: String?
    var email: String?
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
