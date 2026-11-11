import Foundation
import SwiftUI

/// The interface language follows the system's primary language: Simplified Chinese when it is
/// Chinese (any script or region), English for every other language. macOS on its own would take
/// the first language in the whole list that the app has, so a Mac set to Japanese with Chinese
/// second would get Chinese. Where the two differ, the choice is put first in this process's
/// argument domain, exactly as `-AppleLanguages` would: nothing is saved to preferences.
enum InterfaceLanguage {
    static let supported = ["en", "zh-Hans"]

    /// "zh-Hans" or "en" for the user's preferred languages (`Locale.preferredLanguages`).
    static func choice(for preferred: [String]) -> String {
        guard let first = preferred.first?.lowercased() else { return "en" }
        return first == "zh" || first.hasPrefix("zh-") || first.hasPrefix("zh_") ? "zh-Hans" : "en"
    }

    /// The language list this process should use, or nil when macOS already picks the right one.
    static func override(for preferred: [String]) -> [String]? {
        let choice = choice(for: preferred)
        let system = Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first
        return system == choice ? nil : [choice] + preferred
    }

    /// Runs first in `main`, before anything looks up a localized string (the main bundle caches
    /// its language at the first lookup).
    static func apply(defaults: UserDefaults = .standard) {
        guard let languages = override(for: Locale.preferredLanguages) else { return }
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = languages
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}

@main
enum ParleyMain {
    @MainActor static func main() {
        InterfaceLanguage.apply()
        ParleyApp.main()
    }
}
