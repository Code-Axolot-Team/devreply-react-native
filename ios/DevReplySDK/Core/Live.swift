import Foundation
import os

// Live updates over WebSocket (spec 05, "Live updates over WebSocket", SDK 0.5.0): while the messenger is
// open, new messages arrive the moment they're sent. The 3 s poll stays as the fallback and runs only
// while the socket is down.

/// One event from the server. Unknown types (and anything that doesn't decode) are ignored.
enum LiveEvent: Equatable, Sendable {
    /// A new message in one of this install's conversations (the same object as `GET …/messages`).
    case message(conversationID: UUID, message: Message)
    /// The backlog (`after`) is sent: the socket is live.
    case ready
    case unknown

    static func decode(_ text: String) -> LiveEvent {
        let data = Data(text.utf8)
        guard let head = try? APIClient.decoder.decode(Head.self, from: data) else { return .unknown }
        switch head.type {
        case "ready":
            return .ready
        case "message":
            guard let body = try? APIClient.decoder.decode(Body.self, from: data) else { return .unknown }
            return .message(conversationID: body.conversationId, message: body.message)
        default:
            return .unknown
        }
    }

    private struct Head: Decodable { let type: String }
    private struct Body: Decodable {
        let conversationId: UUID
        let message: Message
    }

    /// `{"type":"read","conversation_id":…}`: the conversation is on screen, so the team's replies are read.
    static func readFrame(_ conversationID: UUID) -> String {
        #"{"type":"read","conversation_id":"\#(conversationID.uuidString.lowercased())"}"#
    }
}

/// Live updates are switched off (503), or this server doesn't have them: poll until the messenger opens again.
struct LiveUnavailable: Error {}

/// A WebSocket, as the connection uses it (tests inject a fake).
@MainActor protocol LiveSocket: AnyObject {
    /// The next text frame; `nil` for a frame that isn't text. Throws once the socket is closed or failed.
    func receive() async throws -> String?
    func send(_ text: String) async throws
    /// A WebSocket ping; returns when the pong arrives.
    func ping() async throws
    /// A normal close (1000).
    func close()
}

/// `URLSessionWebSocketTask`. It answers the server's pings itself.
@MainActor final class URLSessionLiveSocket: LiveSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        var request = URLRequest(url: url)
        // Longer than the 75 s dead limit: the connection's own watchdog decides when it's dead.
        request.timeoutInterval = 120
        request.setValue("devreply-ios/\(devReplySDKVersion)", forHTTPHeaderField: "User-Agent")
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let text): return text
        case .data: return nil
        @unknown default: return nil
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func ping() async throws {
        let task = task
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// The messenger's live socket: opened with the messenger, closed when it closes or the app leaves the
/// foreground. Reconnects after a drop with a new ticket and `after`, backing off; after 5 failures in a row it
/// stays on polling until the messenger is opened again.
@MainActor
final class LiveConnection {
    enum State: Equatable, Sendable {
        /// Not wanted (messenger closed, app in the background).
        case off
        case connecting
        /// `ready` came: the chat's poll pauses.
        case live
        /// Waiting to reconnect.
        case waiting
        /// 5 failures in a row: polling until the messenger opens again.
        case gaveUp
        /// Switched off on the server (503) or not there: polling until the messenger opens again.
        case unavailable
    }

    struct Environment {
        /// `POST /v1/live` → the socket URL. Throws `LiveUnavailable` for 503 (poll, don't retry).
        var ticket: @MainActor () async throws -> URL
        var connect: @MainActor (URL) -> LiveSocket
        var sleep: @MainActor (Double) async throws -> Void
        /// Seconds, monotonic.
        var now: @MainActor () -> Double
        /// 0..<1, for the ±20% jitter.
        var random: @MainActor () -> Double
    }

    /// Before reconnect n (0-based) in a row: 1, 2, 4, 8, 16, then 30 s, each ±20%.
    nonisolated static let delays: [Double] = [1, 2, 4, 8, 16, 30]
    nonisolated static let maxFailures = 5
    /// No frame (message, ready or pong) for this long: the socket is dead.
    nonisolated static let deadAfter: Double = 75
    /// The watchdog looks every 15 s and pings once the socket has been quiet that long.
    nonisolated static let checkEvery: Double = 15

    nonisolated static func delay(attempt: Int, random: Double) -> Double {
        let base = delays[min(max(attempt, 0), delays.count - 1)]
        return base * (1 + (random * 2 - 1) * 0.2)
    }

    /// `&after=<id>` added to the ticket's URL.
    nonisolated static func url(_ url: URL, after: UUID?) -> URL {
        guard let after, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "after", value: after.uuidString.lowercased())]
        return parts.url ?? url
    }

    private let env: Environment
    /// The last message id this install has seen (resume point).
    var lastSeen: @MainActor () -> UUID? = { nil }
    var onEvent: @MainActor (LiveEvent) -> Void = { _ in }
    var onStateChange: @MainActor (State) -> Void = { _ in }

    private(set) var state: State = .off {
        didSet { if state != oldValue { Self.log.info("live: \(String(describing: self.state), privacy: .public)"); onStateChange(state) } }
    }
    var isLive: Bool { state == .live }

    private var runner: Task<Void, Never>?
    private var socket: LiveSocket?
    private var lastHeard: Double = 0
    /// Bumped by every start and stop: a finished or cancelled run never touches the state again.
    private var generation = 0

    private static let log = Logger(subsystem: "com.devreply.sdk", category: "live")

    init(environment: Environment) {
        env = environment
    }

    /// The messenger opened (or the app came back with it open). After giving up (or 503) it's a fresh start:
    /// the failure count resets.
    func start() {
        // Already on it (e.g. the app came back while connected).
        if runner != nil, [.connecting, .live, .waiting].contains(state) { return }
        stop()
        generation += 1
        let run = generation
        state = .connecting
        runner = Task { [weak self] in await self?.run(run) }
    }

    /// The messenger closed or the app left the foreground: a normal close, no reconnect.
    func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        socket?.close()
        socket = nil
        state = .off
    }

    /// A frame to the server, while the socket is live (else dropped: the poll covers it).
    func send(_ text: String) {
        guard state == .live, let socket else { return }
        Task { try? await socket.send(text) }
    }

    private enum Outcome { case unavailable, failed, dropped, cancelled }

    private func run(_ run: Int) async {
        var failures = 0
        var reconnects = 0
        var first = true
        while run == generation, !Task.isCancelled {
            if !first {
                state = .waiting
                let wait = Self.delay(attempt: reconnects, random: env.random())
                reconnects += 1
                try? await env.sleep(wait)
                guard run == generation, !Task.isCancelled else { return }
                state = .connecting
            }
            first = false
            switch await connectOnce(run) {
            case .cancelled:
                return
            case .unavailable:
                state = .unavailable
                return
            case .failed:
                failures += 1
                if failures >= Self.maxFailures {
                    state = .gaveUp
                    return
                }
            case .dropped:
                // It was live: the next reconnect starts the backoff from 1 s again.
                failures = 0
                reconnects = 0
            }
        }
    }

    private func connectOnce(_ run: Int) async -> Outcome {
        let ticket: URL
        do {
            ticket = try await env.ticket()
        } catch is LiveUnavailable {
            return run == generation ? .unavailable : .cancelled
        } catch {
            return run == generation && !Task.isCancelled ? .failed : .cancelled
        }
        guard run == generation, !Task.isCancelled else { return .cancelled }
        let socket = env.connect(Self.url(ticket, after: lastSeen()))
        self.socket = socket
        lastHeard = env.now()
        let watchdog = Task { [weak self] in await self?.watch(socket, run) }
        defer { watchdog.cancel() }
        var ready = false
        do {
            while true {
                let text = try await socket.receive()
                guard run == generation else { break }
                lastHeard = env.now()
                guard let text else { continue }
                let event = LiveEvent.decode(text)
                if event == .ready {
                    ready = true
                    state = .live
                }
                onEvent(event)
            }
        } catch {}
        guard run == generation, !Task.isCancelled else { return .cancelled }
        socket.close()
        self.socket = nil
        return ready ? .dropped : .failed
    }

    /// 75 s without any frame = dead: closed here, so `receive` throws and the run reconnects.
    private func watch(_ socket: LiveSocket, _ run: Int) async {
        while !Task.isCancelled {
            try? await env.sleep(Self.checkEvery)
            guard !Task.isCancelled, run == generation, self.socket === socket else { return }
            let quiet = env.now() - lastHeard
            if quiet >= Self.deadAfter {
                Self.log.info("live: no frame for \(Int(quiet)) s, reconnecting")
                socket.close()
                return
            }
            if quiet >= Self.checkEvery {
                Task { [weak self] in
                    guard (try? await socket.ping()) != nil, let self, self.socket === socket else { return }
                    self.lastHeard = self.env.now()
                }
            }
        }
    }
}

extension LiveConnection.Environment {
    /// The real thing: tickets through the messenger's API client, `URLSessionWebSocketTask`, wall-clock sleeps.
    @MainActor static func standard(ticket: @escaping @MainActor () async throws -> URL, session: @escaping @MainActor () -> URLSession) -> Self {
        let clock = ContinuousClock()
        let start = clock.now
        return Self(
            ticket: ticket,
            connect: { URLSessionLiveSocket(url: $0, session: session()) },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            now: {
                let elapsed = start.duration(to: clock.now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            },
            random: { Double.random(in: 0..<1) }
        )
    }
}
