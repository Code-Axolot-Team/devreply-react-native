import SwiftUI

/// A team reply in DevReply Markdown (spec 05, 0.5.0), drawn natively: each block is SwiftUI `Text` from an
/// `AttributedString` (never HTML). Links open in the browser (`openURL`), only the link itself is tappable.
/// Code is monospaced on a tint; headings bold one step larger; lists with a hanging indent; quotes with a
/// bar on the leading side (the right in Hebrew and Arabic). Selectable like any text bubble.
struct MarkdownBubble: View {
    let blocks: [MarkdownBlock]
    var fromUser = false
    /// Outline widths for this appearance.
    @Environment(\.devReplyLine) private var line
    /// Read so the monospaced sizes (scaled by hand) follow Dynamic Type changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var palette: Palette { Palette.active }
    private var ink: Color { fromUser ? palette.userBubbleText : palette.teamBubbleText }
    /// Behind code: the text colour, faint, so it works on any bubble, light or dark.
    private var codeFill: Color { ink.opacity(0.09) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(ink)
        // Links: the bubble's text colour, underlined (set per run), not the system blue.
        .tint(ink)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(BubbleShape(fromUser: fromUser))
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let spans):
            text(spans, size: 17)
        case .heading(let spans):
            text(spans, size: 20, weight: .bold, relativeTo: .title3)
                .accessibilityAddTraits(.isHeader)
        case .quote(let spans):
            text(spans, size: 17)
                .opacity(0.78)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.outline).frame(width: 3 * line)
                }
        case .list(let ordered, let start, let items):
            list(ordered: ordered, start: start, items: items)
        case .code(let code):
            codeBlock(code)
        }
    }

    private func text(_ spans: [MarkdownSpan], size: CGFloat, weight: Font.TextWeight = .medium,
                      relativeTo style: Font.TextStyle = .body) -> some View {
        Text(Self.attributed(spans, size: size, weight: weight, style: style, codeFill: codeFill))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Markers right-aligned in a column as wide as the widest ("10."), the items' lines hanging after it.
    private func list(ordered: Bool, start: Int, items: [[MarkdownSpan]]) -> some View {
        let marker = { (n: Int) in ordered ? "\(start + n)." : "•" }
        let widest = ordered ? marker(items.count - 1) : "•"
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    ZStack(alignment: .trailing) {
                        Text(verbatim: widest).hidden()
                        Text(verbatim: marker(n))
                    }
                    .font(.text(17, .bold))
                    .monospacedDigit()
                    .accessibilityHidden(!ordered)
                    text(item, size: 17)
                }
            }
        }
    }

    /// Monospaced, never wrapped: scrolls sideways when it's wider than the bubble. Code reads left to
    /// right in any language.
    private func codeBlock(_ code: String) -> some View {
        let body = Text(verbatim: code)
            .font(Self.mono(15, relativeTo: .callout))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        return ViewThatFits(in: .horizontal) {
            body
            ScrollView(.horizontal, showsIndicators: false) { body }
        }
        .background(codeFill)
        .overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1.5 * line))
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: Spans

    static func attributed(_ spans: [MarkdownSpan], size: CGFloat, weight: Font.TextWeight, style: Font.TextStyle,
                           codeFill: Color) -> AttributedString {
        var out = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            let textWeight: Font.TextWeight = span.bold ? .bold : weight
            run.font = switch (span.code, span.italic) {
            case (true, false): mono(size - 1.5, bold: span.bold, relativeTo: style)
            case (true, true): mono(size - 1.5, bold: span.bold, relativeTo: style).italic()
            case (false, true): slanted(size, textWeight, relativeTo: style)
            case (false, false): .text(size, textWeight, relativeTo: style)
            }
            if span.strike { run.strikethroughStyle = .single }
            if span.code { run.backgroundColor = codeFill }
            if let link = span.link, let url = URL(string: link) {
                run.link = url
                run.underlineStyle = .single
            }
            out += run
        }
        return out
    }

    /// Space Grotesk has no italic, and `.italic()` doesn't slant a custom font: the brand face, sheared
    /// like a true oblique (about 11°), scaled with Dynamic Type.
    static func slanted(_ size: CGFloat, _ weight: Font.TextWeight, relativeTo style: Font.TextStyle) -> Font {
        _ = BrandFont.register
        guard let upright = UIFont(name: weight.postScriptName, size: size) else {
            return .text(size, weight, relativeTo: style).italic()
        }
        let shear = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        let oblique = UIFont(descriptor: upright.fontDescriptor.withMatrix(shear), size: size)
        return Font(UIFontMetrics(forTextStyle: style.uiKit).scaledFont(for: oblique))
    }

    /// The system's monospaced face at a size that scales with Dynamic Type like the brand fonts do.
    static func mono(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        let scaled = UIFontMetrics(forTextStyle: style.uiKit).scaledValue(for: size)
        return .system(size: scaled, weight: bold ? .bold : .medium, design: .monospaced)
    }
}

private extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
