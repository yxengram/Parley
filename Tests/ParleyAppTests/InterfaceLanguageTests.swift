import Foundation
import Testing
@testable import Parley

// The system's primary language decides: Chinese (any script) gives Simplified Chinese, anything
// else English, even with Chinese later in the list. macOS alone picks the first language the app
// has, so the override is needed exactly where the two differ.

@Test func interfaceLanguageFollowsThePrimaryLanguage() {
    for list in [["zh-Hans"], ["zh-Hans-CN", "en"], ["zh-CN"], ["zh"], ["zh-Hant"], ["zh-Hant-TW", "en"], ["zh-HK"], ["zh_TW"]] {
        #expect(InterfaceLanguage.choice(for: list) == "zh-Hans", "\(list)")
    }
    for list in [["en"], ["en-GB", "zh-Hans"], ["ja"], ["fr"], ["ja", "zh-Hans"], ["de", "zh-Hans-CN", "en"], []] {
        #expect(InterfaceLanguage.choice(for: list) == "en", "\(list)")
    }
}

@Test func theOverrideIsSetOnlyWhereMacOSWouldChooseOtherwise() {
    // macOS already agrees: nothing is set.
    for list in [["zh-Hans"], ["zh-CN", "ja"], ["en"], ["ja"], ["fr", "de"], ["en-GB", "zh-Hans"]] {
        #expect(InterfaceLanguage.override(for: list) == nil, "\(list)")
    }
    // Japanese first with Chinese second: macOS would show Chinese.
    #expect(InterfaceLanguage.override(for: ["ja", "zh-Hans"]) == ["en", "ja", "zh-Hans"])
    // Traditional Chinese: macOS would fall back to English.
    #expect(InterfaceLanguage.override(for: ["zh-Hant-TW", "en"]) == ["zh-Hans", "zh-Hant-TW", "en"])
}
