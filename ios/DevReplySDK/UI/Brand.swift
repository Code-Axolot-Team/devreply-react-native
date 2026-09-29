import CoreText
import SwiftUI

/// The messenger's look. Defaults are DevReply's own "Loud" brand (spec 11): flat colours, 3 pt ink
/// outlines, hard offset shadows, Archivo Black + Space Grotesk. The host app can pass its colours (spec 05).
public struct DevReplyTheme: Sendable {
    /// Header and highlight colour.
    public var primary: Color
    /// Buttons that act: send, start.
    public var accent: Color
    /// The user's own message bubbles.
    public var userBubble: Color
    /// Text on `userBubble`.
    public var userBubbleText: Color
    /// Page background.
    public var background: Color
    /// Outlines, shadows, text.
    public var ink: Color

    public init(
        primary: Color = Brand.lemon,
        accent: Color = Brand.pink,
        userBubble: Color = Brand.cobalt,
        userBubbleText: Color = .white,
        background: Color = Brand.chalk,
        ink: Color = Brand.ink
    ) {
        self.primary = primary
        self.accent = accent
        self.userBubble = userBubble
        self.userBubbleText = userBubbleText
        self.background = background
        self.ink = ink
    }

    @MainActor static var current = DevReplyTheme()
}

/// DevReply brand colours, the same as devreply.com.
public enum Brand {
    public static let lemon = Color(red: 0xF6 / 255, green: 0xEB / 255, blue: 0x37 / 255)
    public static let pink = Color(red: 0xFF / 255, green: 0x5F / 255, blue: 0xA2 / 255)
    public static let cobalt = Color(red: 0x2B / 255, green: 0x50 / 255, blue: 0xE0 / 255)
    public static let ink = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)
    public static let chalk = Color(red: 0xFF / 255, green: 0xFD / 255, blue: 0xF2 / 255)
    public static let grey = Color(red: 0xE9 / 255, green: 0xE6 / 255, blue: 0xD8 / 255)
    public static let muted = Color(red: 0x4A / 255, green: 0x47 / 255, blue: 0x40 / 255)
    public static let online = Color(red: 0x1F / 255, green: 0xB8 / 255, blue: 0x5A / 255)
}

// MARK: - Fonts

enum BrandFont {
    /// Registers the bundled fonts once, for this process only. Never touches the host app's fonts.
    @MainActor static let register: Void = {
        let urls = Bundle.devReply.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

extension Font {
    /// Archivo Black: headlines. Scales with Dynamic Type.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("ArchivoBlack-Regular", size: size, relativeTo: style)
    }

    /// Space Grotesk: everything else. Scales with Dynamic Type.
    static func text(_ size: CGFloat, _ weight: TextWeight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.postScriptName, size: size, relativeTo: style)
    }

    enum TextWeight {
        case regular, medium, bold
        var postScriptName: String {
            switch self {
            case .regular: "SpaceGrotesk-Regular"
            case .medium: "SpaceGrotesk-Medium"
            case .bold: "SpaceGrotesk-Bold"
            }
        }
    }
}

// MARK: - Category icons (SVG, Resources/Icons.xcassets)

extension DevReplyCategory {
    var icon: Image { Image("devreply-\(rawValue)", bundle: .devReply) }

    var defaultTitle: String {
        switch self {
        case .bug: "Something's broken"
        case .billing: "Billing or subscription"
        case .idea: "I have an idea"
        case .question: "Question"
        case .other: "Message"
        }
    }

    var prompt: String {
        switch self {
        case .bug: "What happened, and what did you expect instead? A screenshot helps a lot."
        case .billing: "Tell us what's wrong with your purchase or subscription."
        case .idea: "What would make the app better for you?"
        case .question: "What would you like to know?"
        case .other: "How can we help?"
        }
    }
}

// MARK: - The brutal look: ink outline + hard offset shadow

struct Brutal: ViewModifier {
    var fill: Color = .white
    var shadow: CGFloat = 5
    var lineWidth: CGFloat = 3
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let ink = DevReplyTheme.current.ink
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(ink, lineWidth: lineWidth))
            .background(shape.fill(ink).offset(x: shadow, y: shadow))
    }
}

extension View {
    func brutal(fill: Color = .white, shadow: CGFloat = 5, lineWidth: CGFloat = 3, cornerRadius: CGFloat = 0) -> some View {
        modifier(Brutal(fill: fill, shadow: shadow, lineWidth: lineWidth, cornerRadius: cornerRadius))
    }
}

/// Pressing pushes the element into its shadow, like `.btn:active` on devreply.com.
struct BrutalPressStyle: ButtonStyle {
    var fill: Color = .white
    var shadow: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .brutal(fill: fill, shadow: pressed ? 1 : shadow)
            .offset(x: pressed ? shadow - 1 : 0, y: pressed ? shadow - 1 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Small uppercase label, like the site's `.kicker`.
struct Kicker: View {
    let text: String
    var inverted = false

    var body: some View {
        Text(text.uppercased())
            .font(.text(12, .bold, relativeTo: .caption))
            .tracking(1.2)
            .foregroundStyle(inverted ? Brand.lemon : Brand.ink)
            .padding(.horizontal, inverted ? 8 : 0)
            .padding(.vertical, inverted ? 4 : 0)
            .background(inverted ? Brand.ink : .clear)
    }
}

/// Square icon button with an ink outline (close, back, attach).
struct IconButton: View {
    let systemName: String
    let label: String
    var fill: Color = .white
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .heavy))
                .foregroundStyle(Brand.ink)
                .frame(width: size, height: size)
        }
        .buttonStyle(BrutalPressStyle(fill: fill, shadow: 3))
        .accessibilityLabel(label)
    }
}
