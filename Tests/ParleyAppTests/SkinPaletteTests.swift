import Foundation
import Testing
@testable import Parley

// Every skin must stay as legible and as safe as the first one.

private typealias Token = KeyPath<HideoutPalette, HideoutTone>

private func channels(_ v: UInt32) -> (Double, Double, Double) {
    (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

private func luminance(_ v: UInt32) -> Double {
    func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let (r, g, b) = channels(v)
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func hue(_ v: UInt32) -> Double {
    let (r, g, b) = channels(v)
    let (high, low) = (max(r, g, b), min(r, g, b))
    guard high > low else { return 0 }
    let d = high - low
    let sector = high == r ? (g - b) / d : high == g ? (b - r) / d + 2 : (r - g) / d + 4
    return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
}

private func hueDistance(_ a: UInt32, _ b: UInt32) -> Double {
    let d = abs(hue(a) - hue(b))
    return min(d, 360 - d)
}

private let textOnSurfaces: [(Token, [Token])] = [
    (\.ink, [\.paper, \.paperDeep, \.card, \.composerCard, \.tag, \.peach, \.emberWash]),
    (\.inkSoft, [\.paper, \.card, \.tag, \.peach]),
    (\.inkFaint, [\.paper, \.card]),
    (\.wallInk, [\.wall, \.wallDeep]),
    (\.wallInkSoft, [\.wall]),
    (\.boardInk, [\.board]),
    (\.boardInkSoft, [\.board]),
    (\.onEmber, [\.ember]),
    (\.emberText, [\.paper, \.card, \.emberWash]),
    (\.danger, [\.paper, \.card, \.dangerWash]),
    (\.caution, [\.paper, \.card, \.cautionWash]),
    (\.attention, [\.paper, \.card, \.attentionWash]),
]

private let marksOnSurfaces: [(Token, [Token])] = [
    (\.brass, [\.card, \.tag, \.paper]),
    (\.firefly, [\.paper, \.card]),
    (\.ember, [\.paper, \.card]),
]

@Test(arguments: HideoutSkin.allCases)
func skinTextIsLegible(skin: HideoutSkin) {
    let palette = skin.palette
    for (minimum, pairs) in [(4.5, textOnSurfaces), (3.0, marksOnSurfaces)] {
        for (foreground, surfaces) in pairs {
            for surface in surfaces {
                let fg = palette[keyPath: foreground], bg = palette[keyPath: surface]
                #expect(contrast(fg.light, bg.light) >= minimum, "\(skin) light \(foreground) on \(surface)")
                #expect(contrast(fg.dark, bg.dark) >= minimum, "\(skin) dark \(foreground) on \(surface)")
            }
        }
    }
}

/// A warning must never look like the skin's own accent.
@Test(arguments: HideoutSkin.allCases)
func skinSafetyColoursStayDistinct(skin: HideoutSkin) {
    let p = skin.palette
    #expect(hueDistance(p.danger.light, p.ember.light) >= 18)
    #expect(hueDistance(p.danger.dark, p.ember.dark) >= 18)
    #expect(hueDistance(p.attention.light, p.ember.light) >= 60)
    #expect(hueDistance(p.attention.dark, p.ember.dark) >= 60)
}

@Test(arguments: HideoutSkin.allCases)
func skinHasEveryPicture(skin: HideoutSkin) {
    let art = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Art")
    for name in ["fort-day", "fort-night", "door-day", "door-night"] {
        let file = art.appendingPathComponent(skin.artName(name) + ".jpg")
        #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)")
    }
}
