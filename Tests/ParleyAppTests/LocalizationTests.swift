import Foundation
import Testing

// The interface translations in Resources/*.lproj: both tables parse, have no duplicate keys, every
// English key has a Simplified Chinese value with the same format specifiers, and a key whose
// specifiers are known from the source matches it exactly. Missing translations are reported but
// do not fail here; tools/test_l10n.sh is the strict check.

@Test func localizationTablesAreConsistent() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("tools/l10n_check.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", script.path, "check", "--allow-missing"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(exited.wait(timeout: .now() + 60) == .success, "l10n_check.py did not finish")
    let errors = output.split(separator: "\n").filter { $0.hasPrefix("error: ") || $0.hasPrefix("l10n_check:") }
    #expect(process.terminationStatus == 0, "\(errors.joined(separator: "\n"))")
}

// Parley sets no interface language itself: macOS takes the first preferred language the app has
// (en, zh-Hans), English otherwise. Parley Reader's pickLanguage copies these cases
// (tools/test_reader_page.mjs), so a change in either should show up here.
@Test func macOSPicksTheFirstPreferredLanguageTheAppHas() {
    let supported = ["en", "zh-Hans"]
    let cases: [([String], String)] = [
        (["zh-Hans"], "zh-Hans"), (["zh-CN"], "zh-Hans"), (["zh"], "zh-Hans"), (["zh-SG"], "zh-Hans"),
        (["zh-Hans-HK"], "zh-Hans"), (["zh_CN"], "zh-Hans"),
        (["ja", "zh-Hans"], "zh-Hans"), (["fr", "zh-Hans-CN", "en"], "zh-Hans"),
        (["zh-TW", "zh-CN"], "zh-Hans"), (["zh-HK", "ja", "zh-Hans"], "zh-Hans"),
        (["zh-Hant"], "en"), (["zh-TW"], "en"), (["zh-HK"], "en"), (["zh-MO"], "en"), (["zh-TW", "en"], "en"),
        (["ja"], "en"), (["ja", "fr"], "en"), (["en-GB", "zh-CN"], "en"), (["de", "en"], "en"),
    ]
    for (list, expected) in cases {
        #expect(Bundle.preferredLocalizations(from: supported, forPreferences: list).first == expected, "\(list)")
    }
}
