import CoreText
import SwiftUI
import UIKit

/// The messenger's look. Defaults are DevReply's own "Loud" brand (spec 11): flat colours, 3 pt ink
/// outlines, hard offset shadows, Archivo Black + Space Grotesk. The host app can pass its colours (spec 05),
/// for light (`DevReply.theme`) and dark (`DevReply.darkTheme`); everything else in the chat (cards, text
/// fields, secondary text, outlines, shadows) is worked out from these six.
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

    /// DevReply's own light look (the default).
    public static let light = DevReplyTheme()

    /// DevReply's own dark look, "Deep blue": a deep navy page, light text, a cobalt header, pink buttons.
    /// ```swift
    /// DevReply.darkTheme = .dark     // or DevReplyTheme(primary: …, background: …, ink: …) for your own
    /// ```
    // The dark preset's values live only here.
    public static let dark = DevReplyTheme(
        primary: Color(hex: 0x2B50E0),
        accent: Color(hex: 0xFF5FA2),
        userBubble: Color(hex: 0x3F6BFF),
        userBubbleText: .white,
        background: Color(hex: 0x0E1320),
        ink: Color(hex: 0xEEF1F8)
    )

    @MainActor static var current = DevReplyTheme()
    /// `DevReply.darkTheme`: nil = the chat stays light.
    @MainActor static var currentDark: DevReplyTheme?
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
    public static let mint = Color(red: 0.81, green: 0.95, blue: 0.89)
    public static let error = Color(red: 0.7, green: 0.15, blue: 0.12)
}

extension Color {
    /// `Color(hex: 0x3A3936)`, sRGB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    /// Outline and divider widths for this appearance (1 = the Loud look; 0.5 in the dark look).
    @Entry var devReplyLine: CGFloat = 1
}

/// Every colour the chat draws with, worked out from a theme's six colours and the mode. Light is exactly
/// the look DevReply always had; dark derives cards, secondary text, shadows and text on buttons.
/// With a dark theme, each colour follows the view's appearance (the host's window,
/// `overrideUserInterfaceStyle`); without one, it's the light colour as is.
struct Palette {
    /// The page; cards, fields and bars; text and icons on them; secondary text.
    var background, surface, ink, muted: Color
    /// Borders and dividers; hard shadows.
    var outline, shadow: Color
    /// The home header and the chat's bar, and text on them.
    var header, onHeader: Color
    /// Buttons that act, and text on them.
    var accent, onAccent: Color
    /// The prompt cards (name, email, notifications) and the in-app banner, text and secondary text on them.
    var card, onCard, mutedOnCard: Color
    /// The small brand touches: avatar tiles, file icons, the unread bubble; text on them.
    var brand, onBrand: Color
    /// The team-name tag: text and fill.
    var tagText, tagFill: Color
    var userBubble, userBubbleText, teamBubble, teamBubbleText, notice: Color
    var error, success, resolved, onResolved, placeholder: Color

    nonisolated(unsafe) private static let keys: [WritableKeyPath<Palette, Color>] = [
        \.background, \.surface, \.ink, \.muted, \.outline, \.shadow, \.header, \.onHeader, \.accent,
        \.onAccent, \.card, \.onCard, \.mutedOnCard, \.brand, \.onBrand, \.tagText, \.tagFill, \.userBubble,
        \.userBubbleText, \.teamBubble, \.teamBubbleText, \.notice, \.error, \.success, \.resolved,
        \.onResolved, \.placeholder,
    ]

    /// The light look: exactly what 0.4.3 drew (the colours were fixed there, now named).
    init(light t: DevReplyTheme) {
        background = t.background
        surface = .white
        ink = t.ink
        muted = Brand.muted
        outline = t.ink
        shadow = t.ink
        header = t.primary
        onHeader = t.ink
        accent = t.accent
        onAccent = t.ink
        card = t.primary
        onCard = t.ink
        mutedOnCard = Brand.muted
        brand = t.primary
        onBrand = t.ink
        tagText = t.primary
        tagFill = t.ink
        userBubble = t.userBubble
        userBubbleText = t.userBubbleText
        teamBubble = .white
        teamBubbleText = t.ink
        notice = .white
        error = Brand.error
        success = Brand.online
        resolved = Brand.mint
        onResolved = t.ink
        placeholder = Brand.grey
    }

    /// The dark look, from any dark theme's six colours.
    init(dark t: DevReplyTheme) {
        let bg = RGB(t.background), ink = RGB(t.ink)
        // Cards: 8 % of the way from the page towards the ink tinted halfway to `primary` (plain sRGB).
        let surface = bg.mixed(with: ink.mixed(with: RGB(t.primary), 0.5), 0.08).color
        let dark = Color(hex: 0x111111)
        let lemon = Brand.lemon
        background = t.background
        self.surface = surface
        self.ink = t.ink
        muted = ink.mixed(with: bg, 0.35).color
        outline = t.ink
        shadow = bg.mixed(with: RGB(r: 0, g: 0, b: 0), 0.6).color
        header = t.primary
        onHeader = RGB(t.primary).readableText
        accent = t.accent
        onAccent = RGB(t.accent).readableText
        card = surface
        onCard = t.ink
        mutedOnCard = muted
        brand = lemon
        onBrand = dark
        tagText = dark
        tagFill = lemon
        userBubble = t.userBubble
        userBubbleText = t.userBubbleText
        teamBubble = surface
        teamBubbleText = t.ink
        notice = surface
        error = Color(hex: 0xFF8A7E)
        success = Brand.online
        resolved = Brand.mint
        onResolved = dark
        placeholder = surface
    }

    private init(light l: Palette, dark d: Palette) {
        self = l
        for key in Self.keys { self[keyPath: key] = Self.adaptive(l[keyPath: key], d[keyPath: key]) }
    }

    /// One colour for light and one for dark, resolved by the view's appearance.
    static func adaptive(_ light: Color, _ dark: Color) -> Color {
        let l = UIColor(light), d = UIColor(dark)
        return Color(uiColor: UIColor { traits in
            (traits.userInterfaceStyle == .dark ? d : l).resolvedColor(with: traits)
        })
    }

    /// What the chat uses now: `DevReply.theme`, and `DevReply.darkTheme` in dark appearance if set.
    @MainActor static var active: Palette {
        let light = Palette(light: DevReplyTheme.current)
        guard let dark = DevReplyTheme.currentDark else { return light }
        return Palette(light: light, dark: Palette(dark: dark))
    }

    /// Outline widths for this appearance: the Loud look's in light, half as thick in the dark look.
    @MainActor static func lineScale(_ scheme: ColorScheme) -> CGFloat {
        scheme == .dark && DevReplyTheme.currentDark != nil ? 0.5 : 1
    }

    /// With a dark theme the chat follows the appearance; without one it stays light, as it always was.
    @MainActor static var followsAppearance: Bool { DevReplyTheme.currentDark != nil }
}

/// A colour's sRGB components, for mixing and contrast.
struct RGB: Equatable {
    var r, g, b: Double

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init(_ color: Color) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        (self.r, self.g, self.b) = (Double(r), Double(g), Double(b))
    }

    /// `amount` of the way from this colour to `other`.
    func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// #111111 or white, whichever contrasts better on this colour.
    var readableText: Color {
        let darkText = RGB(r: 17 / 255, g: 17 / 255, b: 17 / 255).luminance
        let onDark = (luminance + 0.05) / (darkText + 0.05)
        let onWhite = 1.05 / (luminance + 0.05)
        return onDark >= onWhite ? Color(hex: 0x111111) : .white
    }
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
    /// The category's artwork; `dark` = the variant drawn for the dark look.
    func icon(dark: Bool) -> Image { Image("devreply-\(rawValue)\(dark ? "-dark" : "")", bundle: .devReply) }

    var defaultTitle: String { t("category.\(rawValue)") }

    var prompt: String { t("prompt.\(rawValue)") }
}

/// A category's icon, resizable and fitted. The dark artwork only in the chat's own dark look (a dark theme
/// is set and the appearance is dark); without a dark theme the chat is light, so is the icon.
struct CategoryIcon: View {
    let category: DevReplyCategory
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        category.icon(dark: colorScheme == .dark && Palette.followsAppearance)
            .resizable()
            .scaledToFit()
    }
}

// MARK: - The brutal look: ink outline + hard offset shadow

struct Brutal: ViewModifier {
    /// Outline and divider widths × the theme's `outlineWidth`.
    @Environment(\.devReplyLine) private var line
    /// `nil` = the theme's `surface`.
    var fill: Color? = nil
    var shadow: CGFloat = 5
    var lineWidth: CGFloat = 3
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let palette = Palette.active
        let ink = palette.outline
        let fill = fill ?? palette.surface
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(ink, lineWidth: lineWidth * line))
            .background(shape.fill(palette.shadow).offset(x: shadow, y: shadow))
    }
}

extension View {
    func brutal(fill: Color? = nil, shadow: CGFloat = 5, lineWidth: CGFloat = 3, cornerRadius: CGFloat = 0) -> some View {
        modifier(Brutal(fill: fill, shadow: shadow, lineWidth: lineWidth, cornerRadius: cornerRadius))
    }
}

/// Pressing pushes the element into its shadow, like `.btn:active` on devreply.com.
struct BrutalPressStyle: ButtonStyle {
    /// `nil` = the theme's `surface`.
    var fill: Color? = nil
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
    private var palette: Palette { Palette.active }

    var body: some View {
        Text(text.uppercased())
            .font(.text(12, .bold, relativeTo: .caption))
            .tracking(1.2)
            .foregroundStyle(inverted ? palette.tagText : palette.ink)
            .padding(.horizontal, inverted ? 8 : 0)
            .padding(.vertical, inverted ? 4 : 0)
            .background(inverted ? palette.tagFill : .clear)
    }
}

/// Square icon button with an ink outline (close, back, attach).
struct IconButton: View {
    let systemName: String
    let label: String
    /// `nil` = the theme's `surface`, with an `ink` icon; on a brand colour, the icon is `onBrand`.
    var fill: Color? = nil
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .heavy))
                .foregroundStyle(fill == nil ? Palette.active.ink : Palette.active.onBrand)
                .frame(width: size, height: size)
        }
        .buttonStyle(BrutalPressStyle(fill: fill, shadow: 3))
        .accessibilityLabel(label)
    }
}
