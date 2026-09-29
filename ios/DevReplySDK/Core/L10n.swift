import Foundation
import Observation

/// The chat's language (spec 05, "Languages"): the app's `DevReply.setLocale`, else the device's
/// preferred languages. Texts come from `DevReplyStrings` (generated from sdk/conformance/strings).
///
/// Views read `t(...)` in their body; on the main actor that read is observed, so changing the
/// language re-renders what's on screen.
@MainActor @Observable
final class L10n {
    static let shared = L10n()

    /// What the app set with `DevReply.setLocale`, as given (nil = follow the device).
    private(set) var override: String?
    /// The table in use, e.g. `es`, `pt-BR`, `zh-Hans`, `en`.
    private(set) var language: String
    /// The tag that matched, e.g. `es-MX` (dates and times use it; the server gets it), or `en`.
    private(set) var tag: String

    private init() {
        let r = Self.resolve(Locale.preferredLanguages)
        language = r.language
        tag = r.tag
        Snapshot.set(language: r.language, tag: r.tag)
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in L10n.shared.update() }
        }
    }

    func set(_ identifier: String?) {
        let trimmed = identifier?.trimmingCharacters(in: .whitespaces)
        override = (trimmed?.isEmpty ?? true) ? nil : trimmed
        update()
    }

    private func update() {
        let r = Self.resolve(override.map { [$0] } ?? Locale.preferredLanguages)
        if r.language != language { language = r.language }
        if r.tag != tag { tag = r.tag }
        Snapshot.set(language: r.language, tag: r.tag)
        Messenger.shared.syncLocale()
    }

    /// Dates and times in the chat's language.
    var locale: Locale { Locale(identifier: tag) }

    // MARK: Resolving (the same rules in every SDK: sdk/conformance/strings/locale-vectors.json)

    /// For each preferred tag in order: an exact match, then `pt*` → `pt-BR` and `zh*` → `zh-Hans`, then
    /// the language alone. Nothing matches: `en`.
    nonisolated static func resolve(_ preferred: [String]) -> (language: String, tag: String) {
        let languages = DevReplyStrings.languages
        for raw in preferred {
            let tag = raw.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { continue }
            if let exact = languages.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return (exact, tag)
            }
            let base = tag.split(separator: "-").first.map { String($0).lowercased() } ?? ""
            if base == "pt" { return ("pt-BR", tag) }
            if base == "zh" { return ("zh-Hans", tag) }
            if let match = languages.first(where: { $0.lowercased() == base }) {
                return (match, tag)
            }
        }
        return ("en", "en")
    }

    // MARK: Texts

    /// The text for `key` in the chat's language, with `{name}` placeholders filled in.
    nonisolated static func t(_ key: String, _ values: [String: String] = [:]) -> String {
        let language = currentLanguage()
        var text = DevReplyStrings.table(language)[key] ?? DevReplyStrings.table("en")[key] ?? key
        for (name, value) in values {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    nonisolated static func has(_ key: String) -> Bool {
        DevReplyStrings.table("en")[key] != nil
    }

    /// On the main actor, read through the observable (so views re-render); elsewhere, the snapshot.
    nonisolated static func currentLanguage() -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { L10n.shared.language }
        }
        return Snapshot.get().language
    }

    nonisolated static var currentTag: String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { L10n.shared.tag }
        }
        return Snapshot.get().tag
    }

    nonisolated static var currentLocale: Locale { Locale(identifier: currentTag) }

    /// The language for code running off the main actor (decoding, the network).
    private enum Snapshot {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var value: (language: String, tag: String) = L10n.resolve(Locale.preferredLanguages)

        static func set(language: String, tag: String) { lock.withLock { value = (language, tag) } }
        static func get() -> (language: String, tag: String) { lock.withLock { value } }
    }
}

/// Shorthand for the chat's texts.
func t(_ key: String, _ values: [String: String] = [:]) -> String { L10n.t(key, values) }
