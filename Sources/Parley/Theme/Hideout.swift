import AppKit
import SwiftUI

/// The design system of Parley's "hideout": a cardboard-and-quilt fort, in afternoon sun (light
/// appearance) or by lantern after lights-out (dark appearance). Colours are the only place
/// the palette is written; every view uses these tokens, never literal or system colours.
enum Hideout {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255,
                           alpha: alpha)
        })
    }

    // MARK: Surfaces

    /// The room: behind everything in the main area.
    static let paper = dynamic(0xFBF1DF, 0x241713)
    /// Recessed areas on paper: inline code, section cards, hover.
    static let paperDeep = dynamic(0xF4E3C6, 0x2F1F19)
    /// Raised cards on paper: the composer, popovers, sheets' fields.
    static let card = dynamic(0xFFF8EA, 0x35231B)
    /// The composer: a card that still stands out where the lantern lights the floor around it.
    static let composerCard = dynamic(0xFFF8EA, 0x4A3126)
    /// Selection and hover on the composer card.
    static let composerWash = dynamic(0xF9DFC4, 0x6E4229)
    /// The cardboard wall behind the conversation list.
    static let wall = dynamic(0xD8B07A, 0x3B261C)
    static let wallDeep = dynamic(0xC4955C, 0x2A1A14)
    /// A paper tag pinned to the wall: the selected conversation, the search field.
    static let tag = dynamic(0xFFF7E8, 0x4F3225)
    /// The user's notes.
    static let peach = dynamic(0xF9CF9A, 0x5A3524)
    /// Chalkboard behind code, in both appearances.
    static let board = dynamic(0x3A2619, 0x17100C)

    // MARK: Text

    /// Main text on paper, card, tag and peach.
    static let ink = dynamic(0x3A2416, 0xF6E7CF)
    /// Secondary text on paper, card, tag and peach (at least 4.5:1 on each).
    static let inkSoft = dynamic(0x6E4F39, 0xBFA286)
    /// Least important metadata on paper and card.
    static let inkFaint = dynamic(0x7A5B41, 0xB89C82)
    /// Text on the bare wall.
    static let wallInk = dynamic(0x2E1B0F, 0xF6E7CF)
    /// Secondary text on the bare wall. Not for wallDeep.
    static let wallInkSoft = dynamic(0x54351F, 0xCDB195)
    static let boardInk = dynamic(0xF6E7CF, 0xF6E7CF)
    static let boardInkSoft = dynamic(0xCDB195, 0xCDB195)

    // MARK: Lines

    static let line = dynamic(0x3A2416, 0xF6E7CF, alpha: 0.16)
    /// Quilt stitching: decorative only.
    static let stitch = dynamic(0xC4955C, 0x7A5238)

    // MARK: Accents

    /// Fills: the primary button, the send button, toggles. Put `onEmber` on it.
    static let ember = dynamic(0xC24A20, 0xF07A44)
    static let onEmber = dynamic(0xFFFFFF, 0x241713)
    /// Ember as text, links and small icons on paper.
    static let emberText = dynamic(0xA8401C, 0xF58A57)
    static let emberWash = dynamic(0xF9DFC4, 0x4A2B1C)
    static let marigold = dynamic(0xEFA92F, 0xFFC24D)
    /// The "working on it" dots: marigold fades into cream paper, so afternoon uses ember.
    static let firefly = dynamic(0xC24A20, 0xFFC24D)
    static let rose = dynamic(0xE0707A, 0xF08F96)
    static let moss = dynamic(0x4F6A22, 0xA5C266)
    static let teal = dynamic(0x2F8F8A, 0x5FC2BA)
    static let plum = dynamic(0x6B3A5B, 0xD29DC0)
    /// Brass padlocks.
    static let brass = dynamic(0x8A6414, 0xE3B95B)

    // MARK: Safety. Must stay distinct from the warm accents; never decorative.

    /// Errors, destructive actions.
    static let danger = dynamic(0xA81E2D, 0xFF6B6B)
    static let dangerWash = dynamic(0xF9D9D5, 0x4A1E22)
    /// Warnings.
    static let caution = dynamic(0x8A5200, 0xFFE08A)
    static let cautionWash = dynamic(0xFBE6B8, 0x453013)
    /// "This needs your decision": approval cards, link confirmation. The one cool colour.
    static let attention = dynamic(0x176A68, 0x5FC2BA)
    static let attentionWash = dynamic(0xD8EBE3, 0x17383A)

    // MARK: Type

    /// Use `.lettered(_:)` on the view: an inherited `fontDesign` otherwise replaces this font.
    fileprivate static func lettered(_ size: CGFloat) -> Font {
        NSFont(name: "Noteworthy-Bold", size: size) != nil
            ? .custom("Noteworthy-Bold", size: size)
            : .system(size: size, weight: .bold, design: .rounded)
    }

    /// Conversation titles and other strong user text.
    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    // MARK: Art

    private static let artCache = NSCache<NSString, NSImage>()

    /// Art shipped in Contents/Resources/Art; nil if the file is missing.
    static func art(_ name: String) -> NSImage? {
        if let cached = artCache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Art"),
              let image = NSImage(contentsOf: url) else { return nil }
        artCache.setObject(image, forKey: name as NSString)
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
        self
            .tint(Hideout.ember)
            .foregroundStyle(Hideout.ink)
            .fontDesign(.rounded)
    }

    /// Hand-lettering. **Fixed English strings only** (no user content: it has no CJK glyphs),
    /// and never for warnings.
    func lettered(_ size: CGFloat) -> some View {
        font(Hideout.lettered(size)).fontDesign(nil)
    }

    /// Root of a sheet or popover: the scene styling on a card background.
    func hideoutSheet() -> some View {
        self
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
                    RadialGradient(colors: [Color(red: 1, green: 0.66, blue: 0.3).opacity(0.14), .clear],
                                   center: UnitPoint(x: 0.5, y: 1.05), startRadius: 0, endRadius: 720)
                } else {
                    RadialGradient(colors: [Color(red: 1, green: 0.78, blue: 0.35).opacity(0.30), .clear],
                                   center: UnitPoint(x: 1.0, y: -0.05), startRadius: 0, endRadius: 760)
                }
            }
            GrainLayer(color: scheme == .dark ? .white : Color(red: 0.35, green: 0.2, blue: 0.08),
                       opacity: scheme == .dark ? 0.10 : 0.16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The cardboard wall: kraft with faint vertical corrugation and grain.
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
