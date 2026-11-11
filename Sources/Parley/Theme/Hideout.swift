import AppKit
import SwiftUI

/// The design system of Parley's "hideout": a secret place in afternoon sun (light appearance) or
/// by lantern after lights-out (dark appearance). The tokens below read the chosen skin's palette
/// (HideoutSkins.swift); every view uses them, never literal or system colours. Read tokens while
/// building a view, not in a deferred closure, or the view will not follow a change of skin.
enum Hideout {
    /// The chosen skin. Reading it from a view body makes that view follow a change of skin.
    static var skin: HideoutSkin { HideoutSkinStore.shared.skin }
    static var palette: HideoutPalette { skin.palette }

    // MARK: Surfaces

    /// The room: behind everything in the main area.
    static var paper: Color { palette.paper.color }
    /// Recessed areas on paper: inline code, section cards, hover.
    static var paperDeep: Color { palette.paperDeep.color }
    /// Raised cards on paper: the composer, popovers, sheets' fields.
    static var card: Color { palette.card.color }
    /// The composer: a card that still stands out where the lantern lights the floor around it.
    static var composerCard: Color { palette.composerCard.color }
    /// Selection and hover on the composer card.
    static var composerWash: Color { palette.composerWash.color }
    /// The cardboard wall behind the conversation list.
    static var wall: Color { palette.wall.color }
    static var wallDeep: Color { palette.wallDeep.color }
    /// A paper tag pinned to the wall: the selected conversation, the search field.
    static var tag: Color { palette.tag.color }
    /// The user's notes.
    static var peach: Color { palette.peach.color }
    /// Chalkboard behind code, in both appearances.
    static var board: Color { palette.board.color }

    // MARK: Text

    /// Main text on paper, card, tag and peach.
    static var ink: Color { palette.ink.color }
    /// Secondary text on paper, card, tag and peach (at least 4.5:1 on each).
    static var inkSoft: Color { palette.inkSoft.color }
    /// Least important metadata on paper and card.
    static var inkFaint: Color { palette.inkFaint.color }
    /// Text on the bare wall.
    static var wallInk: Color { palette.wallInk.color }
    /// Secondary text on the bare wall. Not for wallDeep.
    static var wallInkSoft: Color { palette.wallInkSoft.color }
    static var boardInk: Color { palette.boardInk.color }
    static var boardInkSoft: Color { palette.boardInkSoft.color }

    // MARK: Lines

    static var line: Color { palette.line.color }
    /// Quilt stitching: decorative only.
    static var stitch: Color { palette.stitch.color }

    // MARK: Accents

    /// Fills: the primary button, the send button, toggles. Put `onEmber` on it.
    static var ember: Color { palette.ember.color }
    static var onEmber: Color { palette.onEmber.color }
    /// Ember as text, links and small icons on paper.
    static var emberText: Color { palette.emberText.color }
    static var emberWash: Color { palette.emberWash.color }
    static var marigold: Color { palette.marigold.color }
    /// The "working on it" dots: marigold fades into cream paper, so afternoon uses ember.
    static var firefly: Color { palette.firefly.color }
    static var rose: Color { palette.rose.color }
    static var moss: Color { palette.moss.color }
    static var teal: Color { palette.teal.color }
    static var plum: Color { palette.plum.color }
    /// Brass padlocks.
    static var brass: Color { palette.brass.color }

    // MARK: Safety. Must stay distinct from the skin's accents; never decorative.

    /// Errors, destructive actions.
    static var danger: Color { palette.danger.color }
    static var dangerWash: Color { palette.dangerWash.color }
    /// Warnings.
    static var caution: Color { palette.caution.color }
    static var cautionWash: Color { palette.cautionWash.color }
    /// "This needs your decision": approval cards, link confirmation. The one cool colour.
    static var attention: Color { palette.attention.color }
    static var attentionWash: Color { palette.attentionWash.color }

    // MARK: Type

    /// Use `.lettered(_:)` on the view: an inherited `fontDesign` otherwise replaces this font.
    /// Noteworthy has Latin glyphs only, so in a non-Latin interface language (Chinese) the
    /// lettering is the rounded bold system font, as it is for a non-Latin string.
    fileprivate static func lettered(_ size: CGFloat, handwritten: Bool = true) -> Font {
        handwritten && handLettering && NSFont(name: "Noteworthy-Bold", size: size) != nil
            ? .custom("Noteworthy-Bold", size: size)
            : .system(size: size, weight: .bold, design: .rounded)
    }

    /// Whether the interface language is written in Latin script (English); decided once, at launch,
    /// like the interface language itself.
    static let handLettering: Bool = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: language).language.maximalIdentifier.contains("-Latn")
    }()

    /// Whether every letter of `text` is Latin, so Noteworthy can draw it without a fallback font.
    static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { !$0.properties.isAlphabetic || $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }
    }

    /// Conversation titles and other strong user text.
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    // MARK: Art

    private static let artCache = NSCache<NSString, NSImage>()

    /// A picture of the given skin (by default the chosen one), shipped in
    /// Contents/Resources/Art. Falls back to the cardboard fort's; nil if that is missing too.
    static func art(_ name: String, skin: HideoutSkin? = nil) -> NSImage? {
        let file = (skin ?? Hideout.skin).artName(name)
        if let cached = artCache.object(forKey: file as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: file, withExtension: "jpg", subdirectory: "Art"),
              let image = NSImage(contentsOf: url) else {
            return file == name ? nil : art(name, skin: .cardboard)
        }
        artCache.setObject(image, forKey: file as NSString)
        return image
    }

    /// A tileable alpha-noise tile, tinted by the view that draws it.
    static let grain: CGImage? = {
        let side = 192
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var state: UInt32 = 0x2F6E2B1
        for i in 0..<(side * side) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            data[i] = UInt8(state & 0x3F)
        }
        return ctx.makeImage()
    }()
}

// MARK: - Scene styling

extension View {
    /// Applied at the root of every window, sheet and popover.
    func hideoutScene() -> some View {
        modifier(HideoutSceneStyle())
    }

    /// Hand-lettering, for fixed interface strings (titles, headings), never for warnings or user
    /// content. Noteworthy in English; the rounded bold system font when the interface language is
    /// not written in Latin script (Chinese), since Noteworthy has no CJK glyphs.
    func lettered(_ size: CGFloat) -> some View {
        font(Hideout.lettered(size)).fontDesign(nil)
    }

    /// Hand-lettering for a string that is not a fixed interface string: also falls back to the
    /// rounded bold system font when `text` has non-Latin letters.
    func lettered(_ size: CGFloat, text: String) -> some View {
        font(Hideout.lettered(size, handwritten: Hideout.isLatin(text))).fontDesign(nil)
    }

    /// Root of a sheet or popover: the scene styling on a card background.
    func hideoutSheet() -> some View {
        modifier(HideoutSheetStyle())
    }
}

// Modifiers, not plain chains: they are applied in scene and sheet closures, and a modifier's body
// is what makes those follow a change of skin.
private struct HideoutSceneStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Hideout.ember)
            .foregroundStyle(Hideout.ink)
            .fontDesign(.rounded)
    }
}

private struct HideoutSheetStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .hideoutScene()
            .background(RoomBackground(glow: false))
            .presentationBackground(Hideout.paper)
    }
}

// MARK: - Backgrounds

private struct GrainLayer: View {
    var color: Color
    var opacity: Double

    var body: some View {
        if let grain = Hideout.grain {
            Image(decorative: grain, scale: 2)
                .renderingMode(.template)
                .resizable(resizingMode: .tile)
                .foregroundStyle(color)
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The room's paper with grain and, optionally, the afternoon sun or the lantern's pool of light.
struct RoomBackground: View {
    @Environment(\.colorScheme) private var scheme
    var glow = true

    var body: some View {
        ZStack {
            Hideout.paper
            if glow {
                if scheme == .dark {
                    RadialGradient(colors: [Hideout.palette.glow.color.opacity(0.14), .clear],
                                   center: UnitPoint(x: 0.5, y: 1.05), startRadius: 0, endRadius: 720)
                } else {
                    RadialGradient(colors: [Hideout.palette.glow.color.opacity(0.30), .clear],
                                   center: UnitPoint(x: 1.0, y: -0.05), startRadius: 0, endRadius: 760)
                }
            }
            GrainLayer(color: Hideout.palette.grainTint.color,
                       opacity: scheme == .dark ? 0.10 : 0.16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The wall behind the list: the skin's wall colour with faint vertical corrugation and grain.
struct WallBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Hideout.wall, Hideout.wallDeep.opacity(scheme == .dark ? 1 : 0.55)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 3
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += 7
                }
                context.stroke(path, with: .color(.black.opacity(scheme == .dark ? 0.10 : 0.045)), lineWidth: 1)
            }
            GrainLayer(color: scheme == .dark ? .white : .black, opacity: scheme == .dark ? 0.09 : 0.14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
