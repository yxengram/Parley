import SwiftUI
import ParleyCore

/// Per-conversation request settings: system prompt, temperature, max tokens, reasoning effort
/// (including "None (no thinking)" for every server; with Strata also a thinking budget).
struct ConversationSettingsPopover: View {
    @Environment(AppState.self) private var appState
    @Bindable var session: ConversationSession

    /// The reasoning picker's choices. "None" is stored as `disablesThinking`, not as a
    /// ReasoningEffort case, so older versions still read the file.
    enum Thinking: Hashable {
        case notSent, off, effort(ReasoningEffort)
    }

    private var thinking: Binding<Thinking> {
        Binding(
            get: {
                let s = session.conversation.settings
                if s.disablesThinking == true { return .off }
                return s.reasoningEffort.map(Thinking.effort) ?? .notSent
            },
            set: { choice in
                switch choice {
                case .notSent:
                    session.conversation.settings.reasoningEffort = nil
                    session.conversation.settings.disablesThinking = nil
                case .off:
                    session.conversation.settings.reasoningEffort = nil
                    session.conversation.settings.disablesThinking = true
                case .effort(let e):
                    session.conversation.settings.reasoningEffort = e
                    session.conversation.settings.disablesThinking = nil
                }
                session.settingsChanged(debounced: false)
            }
        )
    }

    /// What the probe found the server to be (nil while unknown or still probing).
    private var serverKind: InferenceServerKind? {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        guard let provider, !model.isEmpty else { return nil }
        return appState.contextInfo(provider: provider, model: model)?.serverKind
    }

    /// The footer's notes under the reasoning settings (none for the defaults).
    static func reasoningNotes(serverKind: InferenceServerKind?, disablesThinking: Bool, hasBudget: Bool) -> [String] {
        if serverKind == .strata {
            return ["Strata: None turns thinking off, High is its highest level, and the budget caps thinking per reply. A small Max Tokens can be used up by thinking alone."]
        }
        var notes: [String] = []
        if disablesThinking {
            notes.append("None asks the server not to think. Not every server or model supports it; a note under the reply says so when Parley can tell it was refused or ignored.")
        }
        if hasBudget {
            // While the probe is pending the server may still turn out to be Strata.
            notes.append(serverKind == nil
                ? "The thinking budget is sent only to Strata."
                : "The thinking budget is sent only to Strata; this server does not get it.")
        }
        return notes
    }

    var body: some View {
        let s = session.conversation.settings
        let kind = serverKind
        let strata = kind == .strata
        let notes = Self.reasoningNotes(serverKind: kind, disablesThinking: s.disablesThinking == true,
                                        hasBudget: s.reasoningBudgetTokens != nil)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt").lettered(17)
                TextEditor(text: Binding(
                    get: { session.conversation.settings.systemPrompt },
                    set: { session.conversation.settings.systemPrompt = $0; session.settingsChanged(debounced: true) }
                ))
                .font(.body)
                .fontDesign(nil)
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .labelsHidden()
                .accessibilityLabel("System Prompt")
                .composerPopoverField()
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stitchedCard(Hideout.card, seed: 41, radius: 14)

            VStack(alignment: .leading, spacing: 9) {
                SettingRow("Temperature") {
                    Toggle("Temperature", isOn: Binding(
                        get: { s.temperature != nil },
                        set: { on in
                            session.conversation.settings.temperature = on ? 0.7 : nil
                            session.settingsChanged(debounced: false)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                if let t = s.temperature {
                    LabeledContent {
                        Slider(value: Binding(
                            get: { t },
                            set: { session.conversation.settings.temperature = ($0 * 100).rounded() / 100; session.settingsChanged(debounced: true) }
                        ), in: 0...2)
                        .labelsHidden()
                    } label: {
                        Text(String(format: "%.2f", t))
                            .monospacedDigit()
                            .foregroundStyle(session.isStreaming ? Hideout.inkFaint : Hideout.inkSoft)
                    }
                }

                StitchRule()

                SettingRow("Max Tokens") {
                    Toggle("Max Tokens", isOn: Binding(
                        get: { s.maxTokens != nil },
                        set: { on in
                            session.conversation.settings.maxTokens = on ? 4096 : nil
                            session.settingsChanged(debounced: false)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                if s.maxTokens != nil {
                    SettingRow("Limit") {
                        TextField("Limit", value: Binding(
                            get: { session.conversation.settings.maxTokens ?? 4096 },
                            set: { session.conversation.settings.maxTokens = max(1, $0); session.settingsChanged(debounced: true) }
                        ), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .composerPopoverField()
                        .frame(width: 110)
                    }
                }

                StitchRule()

                SettingRow("Reasoning Effort") {
                    Picker("Reasoning Effort", selection: thinking) {
                        Text("Not sent").tag(Thinking.notSent)
                        Text("None (no thinking)").tag(Thinking.off)
                        ForEach(ReasoningEffort.allCases, id: \.self) { e in
                            Text(e.rawValue.capitalized).tag(Thinking.effort(e))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                if strata || s.reasoningBudgetTokens != nil {
                    StitchRule()

                    SettingRow("Thinking Budget") {
                        Toggle("Thinking Budget", isOn: Binding(
                            get: { s.reasoningBudgetTokens != nil },
                            set: { on in
                                session.conversation.settings.reasoningBudgetTokens = on ? 4096 : nil
                                session.settingsChanged(debounced: false)
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .disabled(s.disablesThinking == true)
                    if s.reasoningBudgetTokens != nil {
                        SettingRow("Limit") {
                            TextField("Limit", value: Binding(
                                get: { session.conversation.settings.reasoningBudgetTokens ?? 4096 },
                                set: { session.conversation.settings.reasoningBudgetTokens = max(1, $0); session.settingsChanged(debounced: true) }
                            ), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Thinking budget in tokens")
                            .composerPopoverField()
                            .frame(width: 110)
                        }
                        .disabled(s.disablesThinking == true)
                    }
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stitchedCard(Hideout.card, seed: 42, radius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("Settings that are off use the server's default.")
                ForEach(notes, id: \.self) { Text($0) }
            }
            .font(.caption)
            .foregroundStyle(Hideout.inkSoft)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // The single line keeps its usual place (trailing); the notes read better leading.
            .frame(maxWidth: .infinity, alignment: notes.isEmpty ? .trailing : .leading)
            .padding(.horizontal, 6)
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(session.isStreaming)
    }
}

/// One line of the settings card: the title on the left, its control on the right. The control
/// carries the same title for accessibility, so the visible one is not announced twice.
private struct SettingRow<Control: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            // A hidden label no longer dims with its control, so the title does it itself.
            Text(title)
                .foregroundStyle(isEnabled ? Hideout.ink : Hideout.inkFaint)
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            control
        }
    }
}

/// A line of running stitch between groups of rows, matching the room's header.
private struct StitchRule: View {
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }

    var body: some View {
        Line()
            .stroke(Hideout.stitch, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 4]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
