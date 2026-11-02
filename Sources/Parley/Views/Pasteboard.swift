import AppKit

enum Pasteboard {
    /// Copies text locally only: `.currentHostOnly` keeps Universal Clipboard from
    /// syncing it to the user's other devices.
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(string, forType: .string)
    }
}
