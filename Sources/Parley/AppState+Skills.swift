import AppKit
import Foundation
import ParleyCore

/// The skills the tool host offers, readable from any thread. AppState sets it after every look at
/// the skills folder; which of them are switched on is read from the settings at each call.
final class SkillCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SkillSummary] = []

    var summaries: [SkillSummary] { lock.withLock { all } }

    func set(_ summaries: [SkillSummary]) { lock.withLock { all = summaries } }

    /// The settings a built-in call sees: the tools from AppSettings, and the skills that are on.
    @MainActor
    func toolSettings(_ settings: AppSettings) -> BuiltInToolSettings {
        var value = settings.builtInToolSettings
        let off = Set(settings.disabledSkills)
        value.skills = summaries.filter { !off.contains($0.name) }
        return value
    }
}

// Skills on the app side: the list, switching one on or off, importing and removing. Importing copies
// into Parley's skills folder; nothing is fetched and nothing in a skill is run.
extension AppState {
    /// The skills switched on, which every conversation that has not opted out is offered.
    var enabledSkills: [Skill] {
        let off = Set(settings.disabledSkills)
        return skills.filter { !off.contains($0.name) }
    }

    /// What a built-in call would see now: the tools from Settings and the skills that are on.
    var builtInToolSettings: BuiltInToolSettings { skillCatalog.toolSettings(settings) }

    /// Something can be turned on for a conversation: the composer's tools button and ⇧⌘T need it.
    var offersTools: Bool { settings.offersTools || !enabledSkills.isEmpty }

    func isSkillOn(_ skill: Skill) -> Bool { !settings.disabledSkills.contains(skill.name) }

    func setSkill(_ skill: Skill, on: Bool) {
        settings.disabledSkills.removeAll { $0 == skill.name }
        if !on { settings.disabledSkills.append(skill.name) }
    }

    /// Looks at the skills folder again. Quick (a SKILL.md is read per folder), so it runs here.
    func reloadSkills() {
        guard let skillsRoot else { return }
        let contents = SkillLibrary.scan(skillsRoot)
        skills = contents.skills
        skillProblems = contents.problems
        skillCatalog.set(contents.skills.map(\.summary))
    }

    /// Copies what the user picked into a staging folder, off the main thread. Nothing is in use until
    /// `installSkills`.
    func stageSkills(from source: URL) async throws -> SkillLibrary.Staged {
        guard let skillsRoot else { throw SkillImportError.noSkillsFolder }
        return try await Task.detached(priority: .userInitiated) {
            try SkillLibrary.stage(source, into: skillsRoot)
        }.value
    }

    /// Puts the staged skills in place (a folder in the way goes to the Trash) and switches them on.
    @discardableResult
    func installSkills(_ staged: SkillLibrary.Staged) async throws -> [String] {
        let names = staged.skills.map(\.name)
        defer { reloadSkills() }
        let installed = try await Task.detached(priority: .userInitiated) { try SkillLibrary.install(staged) }.value
        settings.disabledSkills.removeAll { names.contains($0) }
        return installed
    }

    func discardStagedSkills(_ staged: SkillLibrary.Staged) {
        SkillLibrary.discard(staged)
    }

    /// To the Trash, where the user can get it back.
    func moveSkillToTrash(_ skill: Skill) throws {
        defer { reloadSkills() }
        try SkillLibrary.moveToTrash(skill)
        settings.disabledSkills.removeAll { $0 == skill.name }
    }

    /// Opens the skills folder in Finder, creating it first so there is something to open.
    func revealSkillsFolder() {
        guard let skillsRoot else { return }
        try? FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([skillsRoot])
    }
}
