import SwiftUI
import ParleyCore

/// Per-conversation request settings: system prompt, temperature, max tokens, reasoning effort.
struct ConversationSettingsPopover: View {
    @Bindable var session: ConversationSession

    var body: some View {
        let s = session.conversation.settings
        Form {
            Section("System Prompt") {
                TextEditor(text: Binding(
                    get: { session.conversation.settings.systemPrompt },
                    set: { session.conversation.settings.systemPrompt = $0; session.settingsChanged(debounced: true) }
                ))
                .font(.body)
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .labelsHidden()
                .accessibilityLabel("System Prompt")
            }

            Section {
                Toggle("Temperature", isOn: Binding(
                    get: { s.temperature != nil },
                    set: { on in
                        session.conversation.settings.temperature = on ? 0.7 : nil
                        session.settingsChanged(debounced: false)
                    }
                ))
                .toggleStyle(.switch)
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
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Max Tokens", isOn: Binding(
                    get: { s.maxTokens != nil },
                    set: { on in
                        session.conversation.settings.maxTokens = on ? 4096 : nil
                        session.settingsChanged(debounced: false)
                    }
                ))
                .toggleStyle(.switch)
                if s.maxTokens != nil {
                    TextField("Limit", value: Binding(
                        get: { session.conversation.settings.maxTokens ?? 4096 },
                        set: { session.conversation.settings.maxTokens = max(1, $0); session.settingsChanged(debounced: true) }
                    ), format: .number)
                    .multilineTextAlignment(.trailing)
                }

                Picker("Reasoning Effort", selection: Binding<ReasoningEffort?>(
                    get: { session.conversation.settings.reasoningEffort },
                    set: { session.conversation.settings.reasoningEffort = $0; session.settingsChanged(debounced: false) }
                )) {
                    Text("Not sent").tag(ReasoningEffort?.none)
                    ForEach(ReasoningEffort.allCases, id: \.self) { e in
                        Text(e.rawValue.capitalized).tag(ReasoningEffort?.some(e))
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("Settings that are off use the server's default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(session.isStreaming)
    }
}
