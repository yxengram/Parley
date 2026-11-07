import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Loads user-picked files as message attachments.
// Images are downscaled and re-encoded, which also strips EXIF/GPS metadata.
// Text files are read as UTF-8 and size-capped.

public enum AttachmentLoader {
    public static let maxTextBytes = 1_000_000
    public static let maxImageDimension = 2048

    /// Upper bound for a source image file, to avoid reading absurdly large files into memory.
    private static let maxImageFileBytes = 200_000_000
    /// PNG output is kept only while it stays under this size; otherwise JPEG is used.
    private static let maxPNGBytes = 4_000_000
    private static let jpegQuality = 0.85

    private static let extraTextTypes: [UTType] = [.json, .yaml, .xml, .commaSeparatedText, .tabSeparatedText, .propertyList]
    private static let extraTextExtensions: Set<String> = ["md", "markdown", "json", "yaml", "yml", "xml", "csv", "tsv", "txt", "log"]

    public static func load(url: URL) throws -> Attachment {
        let filename = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ParleyError.unsupportedAttachment(filename)
        }

        let type = contentType(of: url)

        if let type, type.conforms(to: .image) {
            if fileSize(url) > maxImageFileBytes { throw ParleyError.attachmentTooLarge(filename) }
            let data = try Data(contentsOf: url)
            do {
                return try image(data: data, filename: filename)
            } catch {
                // e.g. SVG: an "image" ImageIO cannot decode, but readable as text.
                if let text = decodeText(data) {
                    if data.count > maxTextBytes { throw ParleyError.attachmentTooLarge(filename) }
                    return Attachment(kind: .text, filename: filename, mimeType: type.preferredMIMEType ?? "text/plain", text: text)
                }
                throw error
            }
        }

        let declaredText = isTextType(type, url: url)
        let size = fileSize(url)

        if declaredText {
            if size > maxTextBytes { throw ParleyError.attachmentTooLarge(filename) }
            let data = try Data(contentsOf: url)
            guard let text = decodeText(data) else { throw ParleyError.unsupportedAttachment(filename) }
            return Attachment(kind: .text, filename: filename, mimeType: textMIME(type), text: text)
        }

        // Unknown type: accept it if it reads as UTF-8 without NUL bytes.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ParleyError.unsupportedAttachment(filename)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes + 1)) ?? Data()
        if data.count > maxTextBytes {
            // Only report "too large" for content that looks like text.
            if decodeTextPrefix(data) { throw ParleyError.attachmentTooLarge(filename) }
            throw ParleyError.unsupportedAttachment(filename)
        }
        guard let text = decodeText(data) else { throw ParleyError.unsupportedAttachment(filename) }
        return Attachment(kind: .text, filename: filename, mimeType: "text/plain", text: text)
    }

    public static func image(data: Data, filename: String) throws -> Attachment {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw ParleyError.unsupportedAttachment(filename)
        }

        var longEdge = maxImageDimension
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           w > 0, h > 0 {
            longEdge = min(maxImageDimension, max(w, h))
        }

        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            throw ParleyError.unsupportedAttachment(filename)
        }

        if hasAlpha(cgImage), let png = encode(cgImage, type: .png, quality: nil), png.count < maxPNGBytes {
            return Attachment(kind: .image, filename: filename, mimeType: "image/png", data: png)
        }

        let opaque = hasAlpha(cgImage) ? (flattenOnWhite(cgImage) ?? cgImage) : cgImage
        guard let jpeg = encode(opaque, type: .jpeg, quality: jpegQuality) else {
            throw ParleyError.unsupportedAttachment(filename)
        }
        return Attachment(kind: .image, filename: filename, mimeType: "image/jpeg", data: jpeg)
    }

    public static func isSupported(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        let type = contentType(of: url)
        if let type, type.conforms(to: .image) { return true }
        if isTextType(type, url: url) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return decodeTextPrefix(data)
    }

    // MARK: - Private helpers

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        let ext = url.pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }

    private static func isTextType(_ type: UTType?, url: URL) -> Bool {
        if extraTextExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type else { return false }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return true }
        return extraTextTypes.contains { type.conforms(to: $0) }
    }

    private static func textMIME(_ type: UTType?) -> String {
        if let mime = type?.preferredMIMEType, !mime.isEmpty { return mime }
        return "text/plain"
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Full decode: valid UTF-8 with no NUL bytes. A leading BOM is dropped.
    static func decodeText(_ data: Data) -> String? {
        if data.contains(0) { return nil }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// Like decodeText, but tolerates a multi-byte character cut off at the end of the sample.
    private static func decodeTextPrefix(_ data: Data) -> Bool {
        if data.contains(0) { return false }
        for cut in 0...min(3, data.count) {
            if String(data: data.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// JPEG has no alpha; composite onto white so transparent areas do not turn black.
    private static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
