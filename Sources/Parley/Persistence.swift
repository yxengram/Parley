import Foundation
import ParleyCore

/// Serializes all conversation encoding + writing onto one background queue.
///
/// Callers snapshot the (value-type) conversation on the main actor and hand it
/// over. Work on this queue never calls back into the main thread synchronously,
/// so `flush()` (queue.sync) from the main thread cannot deadlock.
enum ConversationWriter {
    private static let queue = DispatchQueue(label: "local.parley.save", qos: .userInitiated)

    /// Encode (encrypting when `encryption` is set) and write atomically, asynchronously.
    static func save(
        _ conversation: Conversation,
        encryption: EncryptionKey?,
        to url: URL,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        queue.async {
            completion(performSave(conversation, encryption: encryption, to: url))
        }
    }

    /// Encode and write synchronously on the save queue (after anything already queued).
    @discardableResult
    static func saveSync(_ conversation: Conversation, encryption: EncryptionKey?, to url: URL) -> String? {
        queue.sync {
            performSave(conversation, encryption: encryption, to: url)
        }
    }

    /// Blocks until every queued write has finished.
    static func flush() {
        queue.sync {}
    }

    private static func performSave(_ conversation: Conversation, encryption: EncryptionKey?, to url: URL) -> String? {
        do {
            let data = try ConversationFile.encode(conversation, encryption: encryption)
            try ConversationFile.write(data, to: url)
            return nil
        } catch {
            // Never include content in the error; the description comes from ParleyError/Foundation.
            return error.localizedDescription
        }
    }
}

/// A conversation file known to the library (sidebar). Holds no plaintext of
/// encrypted conversations: `title` is only set for plain files.
struct LibraryEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var isEncrypted: Bool
    var title: String?
    var updatedAt: Date
}

enum LibraryScanner {
    /// Reads headers of all `*.json` conversation files in `directory` plus `extraPaths`.
    /// Runs off the main thread.
    static func scan(directory: URL, extraPaths: [String], hiddenPaths: Set<String>) -> [LibraryEntry] {
        var urls: [URL] = []
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "json" })
        }
        urls = urls.filter { !hiddenPaths.contains(AppSettingsPaths.normalized($0)) }
        for path in extraPaths {
            urls.append(URL(fileURLWithPath: path))
        }

        var seenIDs = Set<UUID>()
        var seenPaths = Set<String>()
        var entries: [LibraryEntry] = []
        for url in urls {
            let norm = AppSettingsPaths.normalized(url)
            guard seenPaths.insert(norm).inserted else { continue }
            guard let entry = entry(for: url), seenIDs.insert(entry.id).inserted else { continue }
            entries.append(entry)
        }
        return entries
    }

    static func entry(for url: URL) -> LibraryEntry? {
        guard let data = try? Data(contentsOf: url),
              let header = try? ConversationFile.peek(data) else { return nil }
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
        return LibraryEntry(
            id: header.id,
            url: url,
            isEncrypted: header.isEncrypted,
            title: header.isEncrypted ? nil : header.title,
            updatedAt: header.updatedAt ?? modDate
        )
    }
}

/// Nonisolated path helpers (usable from background scans).
enum AppSettingsPaths {
    static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
