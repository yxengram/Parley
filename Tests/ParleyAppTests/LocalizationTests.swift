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
