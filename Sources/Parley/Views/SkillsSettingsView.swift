import AppKit
import SwiftUI
import ParleyCore

/// Settings > Skills: the skills in Parley's skills folder, each with a switch. A skill that is on is
/// offered in every conversation (the wrench popover opts one out): the model sees its name and
/// description, and loads its instructions with activate_skill when a request matches.
struct SkillsSettingsView: View {
    @Environment(AppState.self) private var appState
    @ViewState private var importError: String?
    @ViewState private var staged: SkillLibrary.Staged?
    @ViewState private var confirmReplace = false
    @ViewState private var importing = false
    @ViewState private var imported: String?
    @ViewState private var trashCandidate: Skill?
    @ViewState private var confirmTrash = false
    @ViewState private var trashError: String?
    @ViewState private var shownSkill: Skill?

    var body: some View {
        SettingsPage(labelWidth: 196) {
            SettingsSection("Skills", seed: 51) {
                if appState.skills.isEmpty {
                    Text("No skills yet. A skill is a folder with a SKILL.md file: instructions for one kind of task, sometimes with files that go with them. Import one to start.")
                        .font(.callout)
                        .foregroundStyle(Hideout.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(appState.skills) { skill in
                    skillRow(skill)
                }
                HStack(spacing: 8) {
                    Button("Import…", action: chooseImport)
                        .disabled(importing)
                    Button("Show Skills Folder") { appState.revealSkillsFolder() }
                    Button("Reload") { appState.reloadSkills() }
                    if importing { ProgressView().controlSize(.small) }
                }
                if let imported {
                    Label(imported, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Hideout.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let importError {
                    SettingsNotice(.danger, importError, systemImage: "exclamationmark.triangle.fill")
                }
                if let trashError {
                    SettingsNotice(.danger, trashError, systemImage: "exclamationmark.triangle.fill")
                }
            }

            if !appState.skillProblems.isEmpty {
                SettingsSection("Not Loaded", seed: 52) {
                    ForEach(appState.skillProblems) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: ToolDisplay.line(problem.folderName))
                            Text(verbatim: problem.message)
                                .font(.caption)
                                .foregroundStyle(Hideout.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // A note taped up at the end, not a card of controls.
            Text("A skill that is on is offered in every conversation: its name and description go to the model's provider with each request, and when the model loads a skill, its instructions and the files it reads go there too. Parley never runs a skill's scripts or programs, and a skill cannot switch tools on or skip an approval. Import copies a skill into Parley's skills folder; add only skills you trust, since their text tells the model what to do. Import takes a folder with a SKILL.md, a folder of such folders, or a .zip or .skill file of them.")
                .font(.caption)
                .foregroundStyle(Hideout.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .paperCard(Hideout.card, seed: 53, radius: 10)
                .overlay(alignment: .top) {
                    WashiTape(color: Hideout.marigold, width: 66, height: 18, angle: -2)
                        .offset(y: -8)
                }
                .padding(.top, 6)
        }
        .onAppear {
            appState.skillsSettingsVisible = true
            appState.reloadSkills()
        }
        // Closing Settings with a Replace question up, or while an import is staged, throws the
        // staged copy away: nothing would ever answer it.
        .onDisappear {
            appState.skillsSettingsVisible = false
            cancelImport()
        }
        .confirmationDialog(replaceTitle, isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { install() }
            Button("Cancel", role: .cancel) { cancelImport() }
        } message: {
            Text("The skills already there go to the Trash.")
        }
        .confirmationDialog(trashTitle, isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { moveToTrash() }
        } message: {
            Text("Its folder goes to the Trash, where you can get it back.")
        }
        .sheet(item: $shownSkill) { skill in
            SkillManifestSheet(skill: skill)
                .hideoutSheet()
        }
    }

    /// Names the folders that go to the Trash (a skill's folder is usually its name).
    private var replaceTitle: String {
        let names = (staged?.conflicts ?? []).joined(separator: String(localized: ", "))
        return String(localized: "Replace \(names)?")
    }

    private var trashTitle: String {
        String(localized: "Move \(trashCandidate?.name ?? "") to the Trash?")
    }

    private func isOn(_ skill: Skill) -> Binding<Bool> {
        Binding(get: { appState.isSkillOn(skill) }, set: { appState.setSkill(skill, on: $0) })
    }

    private func skillRow(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSwitchRow(isOn: isOn(skill)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ToolDisplay.line(skill.name))
                    Text(verbatim: ToolDisplay.visible(skill.description))
                        .font(.caption)
                        .foregroundStyle(Hideout.inkSoft)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(skill.warnings, id: \.self) { warning in
                SettingsNotice(.caution, warning, systemImage: "exclamationmark.triangle")
            }
            HStack(spacing: 8) {
                Button("Show Instructions") { shownSkill = skill }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.directory]) }
                Button("Move to Trash…") {
                    trashCandidate = skill
                    confirmTrash = true
                }
            }
            .controlSize(.small)
        }
        .padding(.bottom, 4)
    }

    // MARK: Import

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a skill folder (with a SKILL.md), a folder of skills, or a .zip or .skill file.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        imported = nil
        importing = true
        Task {
            do {
                let result = try await appState.stageSkills(from: url)
                guard appState.skillsSettingsVisible else {
                    appState.discardStagedSkills(result)
                    return
                }
                staged = result
                if result.conflicts.isEmpty {
                    install()
                } else {
                    importing = false
                    confirmReplace = true
                }
            } catch {
                importing = false
                importError = error.localizedDescription
            }
        }
    }

    private func install() {
        guard let staged else { return }
        self.staged = nil
        importing = true
        Task {
            do {
                let names = try await appState.installSkills(staged)
                imported = names.count == 1
                    ? String(localized: "Imported \(names[0]).")
                    : String(localized: "Imported \(names.joined(separator: String(localized: ", "))).")
            } catch {
                importError = error.localizedDescription
            }
            importing = false
        }
    }

    private func cancelImport() {
        if let staged { appState.discardStagedSkills(staged) }
        staged = nil
        importing = false
    }

    private func moveToTrash() {
        guard let skill = trashCandidate else { return }
        trashCandidate = nil
        do {
            try appState.moveSkillToTrash(skill)
            trashError = nil
        } catch {
            trashError = String(localized: "\(skill.name) could not be moved to the Trash: \(error.localizedDescription)")
        }
    }
}

/// The whole SKILL.md, as the model would get it (with the frontmatter, which the model does not).
struct SkillManifestSheet: View {
    let skill: Skill
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The skill's own name: user content, so not hand lettering.
            Text(verbatim: ToolDisplay.line(skill.name))
                .font(.title3.weight(.semibold))
            ScrollView {
                Text(verbatim: ToolDisplay.visible(SkillLibrary.manifestText(of: skill)
                    ?? String(localized: "SKILL.md could not be read as text, or is larger than 1 MB.")))
                    .font(.system(.callout, design: .monospaced))
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .settingsWell()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }
}
