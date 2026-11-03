// Renders Resources/icon-src/AppIcon-source.png (full-bleed square artwork) into the
// macOS app icon template (824pt rounded rect on a 1024 canvas) and writes
// Resources/AppIcon.icns. Usage: swift tools/make_icon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/icon-src/AppIcon-source.png")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

guard let image = NSImage(contentsOf: source),
      let art = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(source.path)")
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: rect, cornerWidth: 185.4 * s, cornerHeight: 185.4 * s, transform: nil)
    // Soft drop shadow, as in Apple's template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s,
                  color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(art, in: rect)
    return ctx.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(size: px))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
