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
        static let contextLengthOverrides = "contextLengthOverrides"
        static let learnedContextLengths = "learnedContextLengths"
        static let contextInstanceLinks = "contextInstanceLinks"
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

    /// Context lengths the user entered. Keyed by `contextKey(providerID:model:)`, or by
    /// `contextKey(instanceID:model:)` for a Strata model whose instance id is known, so every
    /// provider (route) that reaches that Strata shares it. Only ids and numbers are stored.
    private(set) var contextLengthOverrides: [String: Int] {
        didSet { defaults.set(contextLengthOverrides, forKey: Key.contextLengthOverrides) }
    }

    /// Context lengths named by the server's overflow errors, keyed like the manual values.
    private(set) var learnedContextLengths: [String: Int] {
        didSet { defaults.set(learnedContextLengths, forKey: Key.learnedContextLengths) }
    }

    /// The Strata instance id each provider and model was last seen with, and at which base URL
    /// (`contextKey(providerID:model:)` → link), so shared values apply right after launch, before
    /// the server is asked again, but not once the provider points somewhere else.
    private(set) var contextInstanceLinks: [String: InstanceLink] {
        didSet { defaults.set(contextInstanceLinks.mapValues(\.plist), forKey: Key.contextInstanceLinks) }
    }

    struct InstanceLink: Equatable {
        var instanceID: String
        /// `AppSettings.normalizedBaseURL` of the provider when the instance was seen.
        var baseURL: String

        var plist: [String: String] { ["id": instanceID, "url": baseURL] }

        init(instanceID: String, baseURL: String) {
            self.instanceID = instanceID
            self.baseURL = baseURL
        }

        init?(plist: Any) {
            guard let d = plist as? [String: String], let id = d["id"], let url = d["url"] else { return nil }
            self.init(instanceID: id, baseURL: url)
        }
    }

    static func normalizedBaseURL(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func contextKey(providerID: UUID, model: String) -> String {
        providerID.uuidString + "|" + model
    }

    static func contextKey(instanceID: String, model: String) -> String {
        "strata:" + instanceID + "|" + model
    }

    /// Where this provider's values for the model live: its Strata instance, else the provider.
    func contextValueKey(providerID: UUID, model: String, instanceID: String?) -> String {
        instanceID.map { Self.contextKey(instanceID: $0, model: model) } ?? Self.contextKey(providerID: providerID, model: model)
    }

    /// The instance the provider reached for the model, while it still points at the same address.
    func linkedInstanceID(providerID: UUID, model: String, baseURL: String) -> String? {
        guard let link = contextInstanceLinks[Self.contextKey(providerID: providerID, model: model)],
              link.baseURL == Self.normalizedBaseURL(baseURL) else { return nil }
        return link.instanceID
    }

    /// The user's value. With an instance id, a value still stored under the provider (entered
    /// before the instance was known) counts until it is moved (`linkInstance`).
    func manualContextLength(providerID: UUID, model: String, instanceID: String? = nil) -> Int? {
        let own = Self.contextKey(providerID: providerID, model: model)
        guard let instanceID else { return contextLengthOverrides[own] }
        return contextLengthOverrides[Self.contextKey(instanceID: instanceID, model: model)] ?? contextLengthOverrides[own]
    }

    /// nil (or a value below 1) removes the override (under both keys, so nothing older comes back).
    func setManualContextLength(_ value: Int?, providerID: UUID, model: String, instanceID: String? = nil) {
        let own = Self.contextKey(providerID: providerID, model: model)
        let key = contextValueKey(providerID: providerID, model: model, instanceID: instanceID)
        if key != own { contextLengthOverrides[own] = nil }
        if let value, value > 0 {
            contextLengthOverrides[key] = value
        } else {
            contextLengthOverrides[key] = nil
        }
    }

    func learnedContextLength(providerID: UUID, model: String, instanceID: String? = nil) -> Int? {
        let own = Self.contextKey(providerID: providerID, model: model)
        guard let instanceID else { return learnedContextLengths[own] }
        return learnedContextLengths[Self.contextKey(instanceID: instanceID, model: model)] ?? learnedContextLengths[own]
    }

    /// Always replaces the previous value: the latest error is the server's current context.
    /// nil removes it (the server now reports its loaded length, or the model was reloaded).
    func setLearnedContextLength(_ value: Int?, providerID: UUID, model: String, instanceID: String? = nil) {
        let own = Self.contextKey(providerID: providerID, model: model)
        let key = contextValueKey(providerID: providerID, model: model, instanceID: instanceID)
        let new = value.flatMap { $0 > 0 ? $0 : nil }
        guard value == nil || new != nil else { return }
        if key != own, learnedContextLengths[own] != nil { learnedContextLengths[own] = nil }
        if learnedContextLengths[key] != new { learnedContextLengths[key] = new }
    }

    /// Forgets the provider's instance link (a probe found another kind of server there), and the
    /// values of an instance no provider reaches any more.
    func unlinkInstance(providerID: UUID, model: String) {
        let own = Self.contextKey(providerID: providerID, model: model)
        guard contextInstanceLinks[own] != nil else { return }
        contextInstanceLinks[own] = nil
        pruneInstanceValues()
    }

    /// Records that this provider, at `baseURL`, reaches Strata instance `instanceID` for the model,
    /// and moves values to the instance key:
    /// - ones stored under the provider (entered before the instance was known);
    /// - when Strata started the model again under a new id (same provider, same address): the
    ///   user's value, and every other provider linked to the old id follows to the new one. A value
    ///   learned from an error is not carried over: the restarted model may have another context,
    ///   and the next overflow names it.
    /// A provider that now points at another address carries nothing over from its old instance.
    /// Values of an instance no link points to any more are removed.
    func linkInstance(_ instanceID: String, providerID: UUID, model: String, baseURL: String) {
        let own = Self.contextKey(providerID: providerID, model: model)
        let key = Self.contextKey(instanceID: instanceID, model: model)
        let url = Self.normalizedBaseURL(baseURL)
        var links = contextInstanceLinks
        let prior = links[own]
        let restartedID = prior.flatMap { $0.baseURL == url && $0.instanceID != instanceID ? $0.instanceID : nil }

        var manual = contextLengthOverrides
        var learned = learnedContextLengths
        if manual[key] == nil {
            manual[key] = manual[own] ?? restartedID.flatMap { manual[Self.contextKey(instanceID: $0, model: model)] }
        }
        if learned[key] == nil { learned[key] = learned[own] }
        manual[own] = nil
        learned[own] = nil

        links[own] = InstanceLink(instanceID: instanceID, baseURL: url)
        if let restartedID {
            // The other routes reached the same running model, so they reach its successor.
            for (linkKey, link) in links where link.instanceID == restartedID && Self.model(ofProviderKey: linkKey) == model {
                links[linkKey]?.instanceID = instanceID
            }
        }
        Self.prune(&manual, links: links)
        Self.prune(&learned, links: links)
        if manual != contextLengthOverrides { contextLengthOverrides = manual }
        if learned != learnedContextLengths { learnedContextLengths = learned }
        if links != contextInstanceLinks { contextInstanceLinks = links }
    }

    private func pruneInstanceValues() {
        var manual = contextLengthOverrides
        var learned = learnedContextLengths
        Self.prune(&manual, links: contextInstanceLinks)
        Self.prune(&learned, links: contextInstanceLinks)
        if manual != contextLengthOverrides { contextLengthOverrides = manual }
        if learned != learnedContextLengths { learnedContextLengths = learned }
    }

    /// Removes instance-keyed values that no link points to.
    private static func prune(_ values: inout [String: Int], links: [String: InstanceLink]) {
        let used = Set(links.map { contextKey(instanceID: $0.value.instanceID, model: model(ofProviderKey: $0.key)) })
        for key in values.keys where key.hasPrefix("strata:") && !used.contains(key) {
            values[key] = nil
        }
    }

    /// The model part of `contextKey(providerID:model:)` (a UUID never contains "|").
    private static func model(ofProviderKey key: String) -> String {
        guard let bar = key.firstIndex(of: "|") else { return key }
        return String(key[key.index(after: bar)...])
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
        self.contextLengthOverrides = (defaults.dictionary(forKey: Key.contextLengthOverrides) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.intValue }
        self.learnedContextLengths = (defaults.dictionary(forKey: Key.learnedContextLengths) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.intValue }
        self.contextInstanceLinks = (defaults.dictionary(forKey: Key.contextInstanceLinks) ?? [:])
            .compactMapValues { InstanceLink(plist: $0) }

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
