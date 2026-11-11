import AppKit
import Foundation
import Observation
import SwiftUI

/// One colour in its afternoon and lights-out versions. The `Color` is built once, so SwiftUI
/// sees the same colour on every read.
struct HideoutTone {
    let light: UInt32
    let dark: UInt32
    let alpha: CGFloat
    let color: Color

    init(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) {
        self.light = light
        self.dark = dark
        self.alpha = alpha
        self.color = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255,
                           alpha: alpha)
        })
    }
}

/// Every colour one skin defines. `Hideout`'s tokens read the chosen skin's palette; what each
/// token is for is documented there.
struct HideoutPalette {
    let paper: HideoutTone
    let paperDeep: HideoutTone
    let card: HideoutTone
    let composerCard: HideoutTone
    let composerWash: HideoutTone
    let wall: HideoutTone
    let wallDeep: HideoutTone
    let tag: HideoutTone
    let peach: HideoutTone
    let board: HideoutTone
    let ink: HideoutTone
    let inkSoft: HideoutTone
    let inkFaint: HideoutTone
    let wallInk: HideoutTone
    let wallInkSoft: HideoutTone
    let boardInk: HideoutTone
    let boardInkSoft: HideoutTone
    let line: HideoutTone
    let stitch: HideoutTone
    let ember: HideoutTone
    let onEmber: HideoutTone
    let emberText: HideoutTone
    let emberWash: HideoutTone
    let marigold: HideoutTone
    let firefly: HideoutTone
    let rose: HideoutTone
    let moss: HideoutTone
    let teal: HideoutTone
    let plum: HideoutTone
    let brass: HideoutTone
    let danger: HideoutTone
    let dangerWash: HideoutTone
    let caution: HideoutTone
    let cautionWash: HideoutTone
    let attention: HideoutTone
    let attentionWash: HideoutTone
    /// The sun (afternoon) or the lantern (lights-out) on the room's paper.
    let glow: HideoutTone
    let grainTint: HideoutTone
    /// Paper flags of the bunting, in hanging order.
    let flags: [HideoutTone]
}

/// The hideouts to choose from. Each has an afternoon and a lights-out look, which follow the
/// system appearance, and its own pictures. Colours only: no skin changes a word or a control.
/// `title` and `blurb` are display text only (localized); the stored value is `rawValue`.
enum HideoutSkin: String, CaseIterable, Identifiable {
    case cardboard
    case pillow
    case treehouse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cardboard: String(localized: "Cardboard Fort")
        case .pillow: String(localized: "Pillow Fort")
        case .treehouse: String(localized: "Treehouse")
        }
    }

    var blurb: String {
        switch self {
        case .cardboard: String(localized: "Kraft and lantern light")
        case .pillow: String(localized: "Pink quilts and cushions")
        case .treehouse: String(localized: "Leaves and fireflies")
        }
    }

    var palette: HideoutPalette {
        switch self {
        case .cardboard: HideoutPalettes.cardboard
        case .pillow: HideoutPalettes.pillow
        case .treehouse: HideoutPalettes.treehouse
        }
    }

    /// File stem of a picture in this skin. The cardboard fort's pictures have no suffix.
    func artName(_ name: String) -> String {
        self == .cardboard ? name : "\(name)-\(rawValue)"
    }
}

/// The chosen skin, a UI preference kept in the app's own defaults. Observable, so every view
/// that reads a `Hideout` token redraws when it changes.
@Observable
final class HideoutSkinStore {
    static let shared = HideoutSkinStore()
    private static let key = "hideout.skin"

    var skin: HideoutSkin {
        didSet { UserDefaults.standard.set(skin.rawValue, forKey: Self.key) }
    }

    private init() {
        skin = UserDefaults.standard.string(forKey: Self.key).flatMap(HideoutSkin.init(rawValue:)) ?? .cardboard
    }
}

enum HideoutPalettes {
    static let cardboard = HideoutPalette(
        paper: HideoutTone(0xFBF1DF, 0x241713),
        paperDeep: HideoutTone(0xF4E3C6, 0x2F1F19),
        card: HideoutTone(0xFFF8EA, 0x35231B),
        composerCard: HideoutTone(0xFFF8EA, 0x4A3126),
        composerWash: HideoutTone(0xF9DFC4, 0x6E4229),
        wall: HideoutTone(0xD8B07A, 0x3B261C),
        wallDeep: HideoutTone(0xC4955C, 0x2A1A14),
        tag: HideoutTone(0xFFF7E8, 0x4F3225),
        peach: HideoutTone(0xF9CF9A, 0x5A3524),
        board: HideoutTone(0x3A2619, 0x17100C),
        ink: HideoutTone(0x3A2416, 0xF6E7CF),
        inkSoft: HideoutTone(0x6E4F39, 0xC3A68A),
        inkFaint: HideoutTone(0x7A5B41, 0xB89C82),
        wallInk: HideoutTone(0x2E1B0F, 0xF6E7CF),
        wallInkSoft: HideoutTone(0x54351F, 0xCDB195),
        boardInk: HideoutTone(0xF6E7CF, 0xF6E7CF),
        boardInkSoft: HideoutTone(0xCDB195, 0xCDB195),
        line: HideoutTone(0x3A2416, 0xF6E7CF, alpha: 0.16),
        stitch: HideoutTone(0xC4955C, 0x7A5238),
        ember: HideoutTone(0xC24A20, 0xF07A44),
        onEmber: HideoutTone(0xFFFFFF, 0x241713),
        emberText: HideoutTone(0xA8401C, 0xF58A57),
        emberWash: HideoutTone(0xF9DFC4, 0x4A2B1C),
        marigold: HideoutTone(0xEFA92F, 0xFFC24D),
        firefly: HideoutTone(0xC24A20, 0xFFC24D),
        rose: HideoutTone(0xE0707A, 0xF08F96),
        moss: HideoutTone(0x4F6A22, 0xA5C266),
        teal: HideoutTone(0x2F8F8A, 0x5FC2BA),
        plum: HideoutTone(0x6B3A5B, 0xD29DC0),
        brass: HideoutTone(0x8A6414, 0xE3B95B),
        danger: HideoutTone(0xA81E2D, 0xFF6B6B),
        dangerWash: HideoutTone(0xF9D9D5, 0x4A1E22),
        caution: HideoutTone(0x8A5200, 0xFFE08A),
        cautionWash: HideoutTone(0xFBE6B8, 0x453013),
        attention: HideoutTone(0x176A68, 0x5FC2BA),
        attentionWash: HideoutTone(0xD8EBE3, 0x17383A),
        glow: HideoutTone(0xFFC759, 0xFFA84D),
        grainTint: HideoutTone(0x593314, 0xFFFFFF),
        flags: [HideoutTone(0xC24A20, 0xF07A44), HideoutTone(0xEFA92F, 0xFFC24D), HideoutTone(0xE0707A, 0xF08F96), HideoutTone(0xFAEDD1, 0xFAEDD1), HideoutTone(0x4F6A22, 0xA5C266)]
    )

    static let pillow = HideoutPalette(
        paper: HideoutTone(0xFFF1F3, 0x26121C),
        paperDeep: HideoutTone(0xFBE0E7, 0x331A26),
        card: HideoutTone(0xFFF9FA, 0x3B1F2D),
        composerCard: HideoutTone(0xFFF9FA, 0x522B3E),
        composerWash: HideoutTone(0xFBD3E0, 0x743A56),
        wall: HideoutTone(0xEFA6BA, 0x42202F),
        wallDeep: HideoutTone(0xDE859E, 0x2E1521),
        tag: HideoutTone(0xFFF5F7, 0x56293E),
        peach: HideoutTone(0xFBCAD8, 0x663048),
        board: HideoutTone(0x4A2035, 0x170A10),
        ink: HideoutTone(0x43182B, 0xFBE7EE),
        inkSoft: HideoutTone(0x74384F, 0xCFA8B8),
        inkFaint: HideoutTone(0x7C4259, 0xC69AAC),
        wallInk: HideoutTone(0x34101F, 0xFBE7EE),
        wallInkSoft: HideoutTone(0x561F35, 0xD9B3C2),
        boardInk: HideoutTone(0xFBE7EE, 0xFBE7EE),
        boardInkSoft: HideoutTone(0xD9B3C2, 0xD9B3C2),
        line: HideoutTone(0x43182B, 0xFBE7EE, alpha: 0.16),
        stitch: HideoutTone(0xDE859E, 0x84506A),
        ember: HideoutTone(0xBE2F74, 0xF578AC),
        onEmber: HideoutTone(0xFFFFFF, 0x26121C),
        emberText: HideoutTone(0xA3265F, 0xF78CB9),
        emberWash: HideoutTone(0xFBD3E0, 0x552238),
        marigold: HideoutTone(0xF4B03F, 0xFFC24D),
        firefly: HideoutTone(0xBE2F74, 0xFFB3D1),
        rose: HideoutTone(0xE5608A, 0xF08FB0),
        moss: HideoutTone(0x4F6A22, 0xA5C266),
        teal: HideoutTone(0x2F8F8A, 0x5FC2BA),
        plum: HideoutTone(0x7A3A78, 0xD29DC0),
        brass: HideoutTone(0x8A6414, 0xE3B95B),
        danger: HideoutTone(0xB3261A, 0xFF7A59),
        dangerWash: HideoutTone(0xF9DDD0, 0x4A2018),
        caution: HideoutTone(0x8A5200, 0xFFE08A),
        cautionWash: HideoutTone(0xFBE6B8, 0x453013),
        attention: HideoutTone(0x176A68, 0x5FC2BA),
        attentionWash: HideoutTone(0xD8EBE3, 0x17383A),
        glow: HideoutTone(0xFF9EB8, 0xFF7FA8),
        grainTint: HideoutTone(0x5A1A35, 0xFFFFFF),
        flags: [HideoutTone(0xBE2F74, 0xF578AC), HideoutTone(0xE5608A, 0xF08FB0), HideoutTone(0xFBEFE4, 0xFBEFE4), HideoutTone(0x7A3A78, 0xD29DC0), HideoutTone(0xF4B03F, 0xFFC24D)]
    )

    static let treehouse = HideoutPalette(
        paper: HideoutTone(0xF8F8DE, 0x1A2012),
        paperDeep: HideoutTone(0xEDEFC2, 0x242C18),
        card: HideoutTone(0xFDFDEC, 0x2C351C),
        composerCard: HideoutTone(0xFDFDEC, 0x3A4624),
        composerWash: HideoutTone(0xE3ECB0, 0x506229),
        wall: HideoutTone(0xBCCB62, 0x2E381B),
        wallDeep: HideoutTone(0x9DB143, 0x1F2711),
        tag: HideoutTone(0xFBFBE8, 0x3D4A24),
        peach: HideoutTone(0xDFE99E, 0x465525),
        board: HideoutTone(0x2B3316, 0x10140A),
        ink: HideoutTone(0x2B3210, 0xEFF2CF),
        inkSoft: HideoutTone(0x4F5823, 0xC4CC9A),
        inkFaint: HideoutTone(0x586229, 0xACB685),
        wallInk: HideoutTone(0x1F260A, 0xEFF2CF),
        wallInkSoft: HideoutTone(0x35401A, 0xC2CB98),
        boardInk: HideoutTone(0xF2F4D6, 0xF2F4D6),
        boardInkSoft: HideoutTone(0xC2CB98, 0xC2CB98),
        line: HideoutTone(0x2B3210, 0xEFF2CF, alpha: 0.16),
        stitch: HideoutTone(0x9DB143, 0x66783A),
        ember: HideoutTone(0x587A0E, 0xB6D84A),
        onEmber: HideoutTone(0xFFFFFF, 0x1A2012),
        emberText: HideoutTone(0x4A6908, 0xC2E25C),
        emberWash: HideoutTone(0xE3ECB0, 0x3D4A1C),
        marigold: HideoutTone(0xE8C22A, 0xF2D64B),
        firefly: HideoutTone(0x587A0E, 0xD9EE6A),
        rose: HideoutTone(0x9CC23E, 0xA8CF52),
        moss: HideoutTone(0x3F6B2A, 0x8FD08A),
        teal: HideoutTone(0x1F8A70, 0x5FC2BA),
        plum: HideoutTone(0x6B4A7B, 0xC4A6D8),
        brass: HideoutTone(0x7A6410, 0xE3C95B),
        danger: HideoutTone(0xA81E2D, 0xFF8080),
        dangerWash: HideoutTone(0xF9D9D5, 0x4A1E22),
        caution: HideoutTone(0x8A5200, 0xFFE08A),
        cautionWash: HideoutTone(0xFBE6B8, 0x453013),
        attention: HideoutTone(0x15657A, 0x6CC3DB),
        attentionWash: HideoutTone(0xD6EAF0, 0x17343F),
        glow: HideoutTone(0xD9F06A, 0xC6E85A),
        grainTint: HideoutTone(0x3D4412, 0xFFFFFF),
        flags: [HideoutTone(0x8CB02A, 0xB6D84A), HideoutTone(0xE8C22A, 0xF2D64B), HideoutTone(0xFBF7DC, 0xFBF7DC), HideoutTone(0x4F7A1E, 0x8FBF5A), HideoutTone(0xC9DA5E, 0xD9EE6A)]
    )
}
