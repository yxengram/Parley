import Foundation
import Observation
import ParleyCore

/// App-wide settings persisted in `UserDefaults` (never iCloud).
///
/// Only non-sensitive configuration lives here: provider profiles (no API keys;
/// those are in the Keychain), directory paths and UI preferences. Conversation
/// titles or content are never written to UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let providers = "providers"
        static let defaultProviderID = "defaultProviderID"
        static let defaultDirectoryPath = "defaultDirectoryPath"
        static let extraConversationPaths = "extraConversationPaths"
        static let hiddenConversationPaths = "hiddenConversationPaths"
        static let showTokenUsage = "showTokenUsage"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var providers: [Provider] {
        didSet { persistProviders() }
    }

    var defaultProviderID: UUID? {
        didSet { defaults.set(defaultProviderID?.uuidString, forKey: Key.defaultProviderID) }
    }

    var defaultDirectoryPath: String {
        didSet { defaults.set(defaultDirectoryPath, forKey: Key.defaultDirectoryPath) }
    }

    /// File paths of conversations that live outside the default directory. Paths only.
    var extraConversationPaths: [String] {
        didSet { defaults.set(extraConversationPaths, forKey: Key.extraConversationPaths) }
    }

    /// File paths in the default directory the user removed from the list. Paths only.
    var hiddenConversationPaths: [String] {
        didSet { defaults.set(hiddenConversationPaths, forKey: Key.hiddenConversationPaths) }
    }

    /// UI preference: show token usage under assistant messages.
    var showTokenUsage: Bool {
        didSet { defaults.set(showTokenUsage, forKey: Key.showTokenUsage) }
    }

    static var builtInDefaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Parley", isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var loadedProviders: [Provider] = []
        if let data = defaults.data(forKey: Key.providers),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            loadedProviders = decoded
        }
        let firstLaunch = defaults.object(forKey: Key.providers) == nil
        if firstLaunch && loadedProviders.isEmpty {
            loadedProviders = [Provider(name: "LM Studio (local)", baseURL: "http://localhost:1234/v1")]
        }
        self.providers = loadedProviders

        if let s = defaults.string(forKey: Key.defaultProviderID), let id = UUID(uuidString: s) {
            self.defaultProviderID = id
        } else {
            self.defaultProviderID = loadedProviders.first?.id
        }

        if let path = defaults.string(forKey: Key.defaultDirectoryPath), !path.isEmpty {
            self.defaultDirectoryPath = path
        } else {
            self.defaultDirectoryPath = Self.builtInDefaultDirectory.path
        }

        self.extraConversationPaths = defaults.stringArray(forKey: Key.extraConversationPaths) ?? []
        self.hiddenConversationPaths = defaults.stringArray(forKey: Key.hiddenConversationPaths) ?? []
        self.showTokenUsage = defaults.object(forKey: Key.showTokenUsage) as? Bool ?? true

        if firstLaunch {
            persistProviders()
            defaults.set(defaultProviderID?.uuidString, forKey: Key.defaultProviderID)
        }
    }

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Key.providers)
        }
    }

    var defaultDirectoryURL: URL {
        URL(fileURLWithPath: (defaultDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    func provider(id: UUID?) -> Provider? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    /// The provider a conversation should use: its own, else the default, else the first.
    func resolvedProvider(for settings: ConversationSettings) -> Provider? {
        provider(id: settings.providerID) ?? provider(id: defaultProviderID) ?? providers.first
    }

    var defaultProvider: Provider? {
        provider(id: defaultProviderID) ?? providers.first
    }

    // MARK: Paths

    static func normalizedPath(_ url: URL) -> String {
        AppSettingsPaths.normalized(url)
    }

    func isInDefaultDirectory(_ fileURL: URL) -> Bool {
        let dir = Self.normalizedPath(fileURL.deletingLastPathComponent())
        return dir == Self.normalizedPath(defaultDirectoryURL)
    }

    /// Makes sure a conversation file outside the default directory stays in the library.
    func rememberConversationFile(_ fileURL: URL) {
        let path = Self.normalizedPath(fileURL)
        hiddenConversationPaths.removeAll { $0 == path }
        if !isInDefaultDirectory(fileURL), !extraConversationPaths.contains(path) {
            extraConversationPaths.append(path)
        }
    }

    func forgetConversationFile(_ fileURL: URL, hide: Bool) {
        let path = Self.normalizedPath(fileURL)
        extraConversationPaths.removeAll { $0 == path }
        if hide, isInDefaultDirectory(fileURL), !hiddenConversationPaths.contains(path) {
            hiddenConversationPaths.append(path)
        }
        if !hide {
            hiddenConversationPaths.removeAll { $0 == path }
        }
    }
}
