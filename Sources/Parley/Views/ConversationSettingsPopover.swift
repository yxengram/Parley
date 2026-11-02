import SwiftUI
import ParleyCore

/// Per-conversation request settings: system prompt, temperature, max tokens, reasoning effort.
struct ConversationSettingsPopover: View {
    @Bindable var session: ConversationSession

    var body: some View {
        let s = session.conversation.settings
        VStack(alignment: .leading, spacing: 14) {
            Text("Conversation Settings").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt").font(.subheadline.weight(.medium))
                TextEditor(text: Binding(
                    get: { session.conversation.settings.systemPrompt },
                    set: { session.conversation.settings.systemPrompt = $0; session.settingsChanged(debounced: true) }
                ))
                .font(.body)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Temperature", isOn: Binding(
                    get: { s.temperature != nil },
                    set: { on in
                        session.conversation.settings.temperature = on ? 0.7 : nil
                        session.settingsChanged(debounced: false)
                    }
                ))
                if let t = s.temperature {
                    HStack {
                        Slider(value: Binding(
                            get: { t },
                            set: { session.conversation.settings.temperature = ($0 * 100).rounded() / 100; session.settingsChanged(debounced: true) }
                        ), in: 0...2)
                        Text(String(format: "%.2f", t))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } else {
                    Text("Server default").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Max tokens", isOn: Binding(
                    get: { s.maxTokens != nil },
                    set: { on in
                        session.conversation.settings.maxTokens = on ? 4096 : nil
                        session.settingsChanged(debounced: false)
                    }
                ))
                if s.maxTokens != nil {
                    TextField("Max tokens", value: Binding(
                        get: { session.conversation.settings.maxTokens ?? 4096 },
                        set: { session.conversation.settings.maxTokens = max(1, $0); session.settingsChanged(debounced: true) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                } else {
                    Text("Server default").font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Reasoning effort", selection: Binding<ReasoningEffort?>(
                get: { session.conversation.settings.reasoningEffort },
                set: { session.conversation.settings.reasoningEffort = $0; session.settingsChanged(debounced: false) }
            )) {
                Text("Not sent").tag(ReasoningEffort?.none)
                ForEach(ReasoningEffort.allCases, id: \.self) { e in
                    Text(e.rawValue.capitalized).tag(ReasoningEffort?.some(e))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(16)
        .frame(width: 360)
        .disabled(session.isStreaming)
    }
}
