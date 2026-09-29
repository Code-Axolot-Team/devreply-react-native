import Foundation

enum DevReplyError: Error, Equatable {
    /// The install token was rejected (revoked, or the server lost it). Register again.
    case unauthenticated
    /// The public key is unknown or revoked.
    case invalidPublicKey
    case notFound
    case invalid(String)
    case server(Int)
    /// The server can't do this right now (e.g. attachments not enabled).
    case unavailable
    case network
}

/// The public API (spec 07): `pk_` registers an install, the `it_` token does everything else.
struct APIClient: Sendable {
    let baseURL: URL
    var session: URLSession = .shared

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseRFC3339(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }()

    func registerInstall(publicKey: String, device: DeviceInfo) async throws -> RegisteredInstall {
        var body = device.json
        body["public_key"] = publicKey
        do {
            return try await send("POST", "v1/installs", token: nil, body: body)
        } catch DevReplyError.unauthenticated {
            throw DevReplyError.invalidPublicKey
        }
    }

    func deepLinkOpened(token: String) async throws {
        let _: Empty = try await send("POST", "v1/deep_link_opened", token: token)
    }

    /// For responses without a body (204).
    struct Empty: Decodable {}

    func config(token: String) async throws -> MessengerConfig {
        try await send("GET", "v1/messenger/config", token: token)
    }

    func conversations(token: String) async throws -> [Conversation] {
        let list: Lossy<Conversation> = try await send("GET", "v1/conversations", token: token)
        return list.items
    }

    func startConversation(
        token: String, category: DevReplyCategory?, text: String, attachments: [UUID]
    ) async throws -> StartedConversation {
        try await send(
            "POST", "v1/conversations", token: token,
            body: MessageBody(text: text, category: category?.rawValue, attachmentIds: attachments)
        )
    }

    func messages(token: String, conversation: UUID) async throws -> MessagesPage {
        try await send("GET", "v1/conversations/\(conversation.uuidString.lowercased())/messages", token: token)
    }

    func sendMessage(token: String, conversation: UUID, text: String, attachments: [UUID]) async throws -> Message {
        try await send(
            "POST", "v1/conversations/\(conversation.uuidString.lowercased())/messages", token: token,
            body: MessageBody(text: text, category: nil, attachmentIds: attachments)
        )
    }

    func updatePushToken(token: String, pushToken: String?, environment: String) async throws {
        let _: PushResult = try await send(
            "PATCH", "v1/install", token: token, body: PushBody(pushToken: pushToken, pushEnv: environment)
        )
    }

    private struct PushBody: Encodable {
        let pushToken: String?
        let pushEnv: String
        enum CodingKeys: String, CodingKey { case pushToken = "push_token", pushEnv = "push_env" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pushToken, forKey: .pushToken) // null turns pushes off
            try c.encode(pushEnv, forKey: .pushEnv)
        }
    }

    private struct PushResult: Decodable { let push: Bool }

    /// The chat's language changed. Only the locale: the server leaves push alone when no token is sent.
    func updateLocale(token: String, locale: String) async throws {
        let _: PushResult = try await send("PATCH", "v1/install", token: token, body: ["locale": locale])
    }

    func profile(token: String) async throws -> Profile {
        try await send("GET", "v1/me", token: token)
    }

    func updateProfile(
        token: String, name: String?, email: String?, attributes: [String: DevReplyAttribute?] = [:]
    ) async throws -> Profile {
        try await send("PATCH", "v1/me", token: token, body: ProfileBody(name: name, email: email, attributes: attributes))
    }

    private struct ProfileBody: Encodable {
        let name: String?
        let email: String?
        let attributes: [String: DevReplyAttribute?]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(email, forKey: .email)
            // nil values must reach the server as JSON null (= remove the attribute).
            var attrs = c.nestedContainer(keyedBy: AnyKey.self, forKey: .attributes)
            for (key, value) in attributes {
                if let value { try attrs.encode(value, forKey: AnyKey(key)) } else { try attrs.encodeNil(forKey: AnyKey(key)) }
            }
        }

        private enum Keys: String, CodingKey { case name, email, attributes }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Asks the server for a one-time upload URL, then uploads straight to storage (no Firebase SDK needed).
    func upload(token: String, attachment: OutgoingAttachment) async throws -> UUID {
        let slot: UploadSlot = try await send(
            "POST", "v1/attachments", token: token,
            body: AttachmentRequest(
                kind: attachment.kind, mime: attachment.mime, size: attachment.data.count,
                width: attachment.width, height: attachment.height, filename: attachment.filename
            )
        )
        let jpeg = attachment.data
        var put = URLRequest(url: slot.uploadUrl)
        put.httpMethod = "PUT"
        put.timeoutInterval = 60
        for (k, v) in slot.uploadHeaders { put.setValue(v, forHTTPHeaderField: k) }
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: put, from: jpeg)
        } catch {
            throw DevReplyError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DevReplyError.server(status) }
        return slot.id
    }

    private struct MessageBody: Encodable {
        let text: String
        let category: String?
        let attachmentIds: [UUID]

        enum CodingKeys: String, CodingKey { case text, category, attachmentIds = "attachment_ids" }
    }

    private struct AttachmentRequest: Encodable {
        let kind: String
        let mime: String
        let size: Int
        let width: Int?
        let height: Int?
        let filename: String?
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, token: String?, body: (any Encodable)? = nil
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("devreply-ios/\(devReplySDKVersion)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DevReplyError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            if data.isEmpty, let empty = Empty() as? T { return empty }
            return try Self.decoder.decode(T.self, from: data)
        case 401:
            throw DevReplyError.unauthenticated
        case 404:
            throw DevReplyError.notFound
        case 503:
            throw DevReplyError.unavailable
        case 400:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? "Invalid request"
            throw DevReplyError.invalid(message)
        default:
            throw DevReplyError.server(status)
        }
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}

/// RFC 3339 with or without fractional seconds (the server sends microseconds).
func parseRFC3339(_ s: String) -> Date? {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    guard let dot = s.firstIndex(of: ".") else { return plain.date(from: s) }
    let afterDot = s[s.index(after: dot)...]
    let digits = afterDot.prefix { $0.isNumber }
    let zone = afterDot.dropFirst(digits.count)
    guard let base = plain.date(from: String(s[..<dot]) + zone) else { return nil }
    let fraction = Double("0." + digits) ?? 0
    return base.addingTimeInterval(fraction)
}
