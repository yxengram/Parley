import SwiftUI
import ParleyCore

// The status strip at the bottom-right of the chat (generation speed, context usage) and its
// popover (where the limit comes from, a manual value, and LM Studio's reload).

/// Number formatting shared by the strip, the popover and message footers.
enum TokenFormat {
    /// Token counts and context sizes in one unit, k = 1024 tokens (context sizes are powers of
    /// two), so a count keeps its value when a limit appears next to it and a nearly full
    /// context never reads as over the limit:
    /// 950 → "950", 12_431 → "12.1k", 32_768 → "32k", 262_144 → "256k", 1_048_576 → "1M".
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case ..<1024: return "\(n)"
        case ..<(100 * 1024): return trimmed(v / 1024, digits: 1) + "k"
        case ..<(1024 * 1024): return "\(Int((v / 1024).rounded()))k"
        default: return trimmed(v / 1_048_576, digits: 2) + "M"
        }
    }

    /// The user's typed token count: digits, optionally with grouping separators ("32,768",
    /// "32 768"). Nil for anything else, or for zero.
    static func parse(_ text: String) -> Int? {
        let separators = Set<Character>([",", ".", "'", "_", " ", "\u{00A0}", "\u{202F}"])
            .union(Locale.current.groupingSeparator ?? "")
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).filter { !separators.contains($0) }
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(digits), n > 0 else { return nil }
        return n
    }

    static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// 42.33 → "42.3", 123.4 → "123", 4.56 → "4.6".
    static func rate(_ r: Double) -> String {
        r >= 100 ? "\(Int(r.rounded()))" : String(format: "%.1f", r)
    }

    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }

    static func percent(_ p: Double) -> String {
        p < 10 && p > 0 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }

    private static func trimmed(_ v: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Everything the strip and popover show, computed once per render.
struct ContextSnapshot: Equatable {
    var usage: ContextUsage
    var limit: ContextLimit?
    var info: ModelContextInfo?
    var manual: Int?
    /// The size the server's last overflow error named (kept across launches).
    var learned: Int? = nil
    /// The values are shared with other providers reaching the same Strata instance.
    var sharedInstance = false
    var isProbing: Bool
    /// Live while streaming, else the last reply's.
    var tokensPerSecond: Double?
    var speedIsEstimated: Bool
    var timeToFirstToken: Double?
    /// The last reply's prompt reading (Strata, llama.cpp timings).
    var promptTokensPerSecond: Double? = nil
    var promptTokensRead: Int? = nil
    var cachedPromptTokens: Int? = nil
    /// While streaming, before the first token.
    var promptProgress: PromptProgress? = nil
    var isStreaming: Bool
    var reload: AppState.ReloadState?

    var percent: Double? { limit.map { usage.percent(of: $0.tokens) } }

    /// Orange from 80 %, red from 95 %.
    var tint: Color {
        guard let p = percent else { return .secondary }
        if p >= 95 { return .red }
        if p >= 80 { return .orange }
        return .accentColor
    }

    @MainActor
    static func make(session: ConversationSession, appState: AppState) -> (ContextSnapshot, Provider?, String) {
        let provider = appState.settings.resolvedProvider(for: session.conversation.settings)
        let model = ConversationSession.effectiveModel(settings: session.conversation.settings, provider: provider)
        let info = provider.flatMap { model.isEmpty ? nil : appState.contextInfo(provider: $0, model: model) }
        let manual = provider.flatMap { model.isEmpty ? nil : appState.manualContextLength(provider: $0, model: model) }
        let learned = provider.flatMap { model.isEmpty ? nil : appState.learnedContextLength(provider: $0, model: model) }
        let instance = provider.flatMap { model.isEmpty ? nil : appState.contextInstanceID(provider: $0, model: model) }
        let live = session.liveGeneration
        let usage = session.contextUsage()
        var rate: Double?
        var estimated = false
        var ttft: Double?
        var lastStats: GenerationStats?
        if let live {
            rate = live.tokensPerSecond
            estimated = live.isEstimated
        } else if let stats = session.conversation.messages.last(where: { $0.role == .assistant && $0.stats != nil })?.stats {
            rate = stats.tokensPerSecond
            estimated = stats.isEstimated ?? false
            ttft = stats.timeToFirstToken
            lastStats = stats
        }
        let snapshot = ContextSnapshot(
            usage: usage,
            limit: ContextBudget.limit(info: info, manual: manual, learned: learned),
            info: info,
            manual: manual,
            learned: learned,
            sharedInstance: instance != nil,
            isProbing: provider.map { appState.isProbingContext(provider: $0, model: model) } ?? false,
            tokensPerSecond: rate,
            speedIsEstimated: estimated,
            timeToFirstToken: ttft,
            promptTokensPerSecond: lastStats?.promptTokensPerSecond,
            promptTokensRead: lastStats?.promptTokensRead,
            cachedPromptTokens: lastStats?.cachedPromptTokens,
            promptProgress: live?.promptProgress,
            isStreaming: session.isStreaming,
            reload: provider.flatMap { model.isEmpty ? nil : appState.reloadState(provider: $0, model: model) }
        )
        return (snapshot, provider, model)
    }
}

// MARK: - Strip

struct ContextStatusBar: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession
    @ViewState private var showPopover = false

    var body: some View {
        let (snap, provider, model) = ContextSnapshot.make(session: session, appState: appState)
        HStack {
            Spacer(minLength: 0)
            Button { showPopover.toggle() } label: {
                label(snap)
            }
            .buttonStyle(.plain)
            .help(helpText(snap, provider: provider))
            .accessibilityLabel(Self.accessibilityText(snap))
            .accessibilityHint("Shows context details")
            // The strip sits on the window's bottom edge: open upwards, into the window.
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                if let provider, !model.isEmpty {
                    ContextPopover(session: session, provider: provider, model: model)
                } else {
                    Text("Choose a model to see its context length.")
                        .padding(16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: SnapshotHarness.showContextPopoverNotification)) { _ in
            showPopover = true
        }
        #endif
    }

    private func label(_ snap: ContextSnapshot) -> some View {
        HStack(spacing: 6) {
            if snap.isStreaming, let progress = snap.promptProgress {
                // Prompt reading (Strata, llama.cpp) before the first token.
                HStack(spacing: 3) {
                    Image(systemName: "text.viewfinder")
                        .imageScale(.small)
                    Text("Reading prompt \(Int((progress.fraction * 100).rounded(.down)))%")
                }
                Text("·").foregroundStyle(.tertiary)
            } else if snap.isStreaming || snap.tokensPerSecond != nil {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .imageScale(.small)
                    Text(speedText(snap))
                }
                .foregroundStyle(snap.isStreaming ? Color.primary : Color.secondary)
                Text("·").foregroundStyle(.tertiary)
            }
            if case .failed = snap.reload {
                Label("Reload failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(StripLabelStyle())
                    .foregroundStyle(.red)
                Text("·").foregroundStyle(.tertiary)
            }
            if snap.reload?.isRunning == true {
                ProgressView().controlSize(.mini)
                Text("Reloading model…").foregroundStyle(.secondary)
            } else if let limit = snap.limit {
                ContextRing(fraction: (snap.percent ?? 0) / 100, tint: snap.tint)
                // Only the model's maximum is known: the loaded size may be much smaller.
                let limitText = (limit.source == .serverMaximum ? "max " : "") + TokenFormat.tokens(limit.tokens)
                Text(usageText(snap.usage) + " / " + limitText
                     + (snap.usage.tokens > 0 ? " (" + TokenFormat.percent(snap.percent ?? 0) + ")" : ""))
                    .foregroundStyle((snap.percent ?? 0) >= 80 ? snap.tint : Color.secondary)
            } else if snap.isProbing && snap.info == nil {
                Text("Context: checking…").foregroundStyle(.secondary)
            } else {
                if snap.usage.tokens > 0 {
                    Text(usageText(snap.usage) + " tokens").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text("Context: unknown — set…").foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .modifier(StatusCapsuleBackground())
        .contentShape(Capsule())
    }

    private func usageText(_ usage: ContextUsage) -> String {
        guard usage.tokens > 0 else { return "—" }
        return (usage.isEstimated ? "≈" : "") + TokenFormat.tokens(usage.tokens)
    }

    private func speedText(_ snap: ContextSnapshot) -> String {
        guard let r = snap.tokensPerSecond else { return "— tok/s" }
        return (snap.speedIsEstimated ? "≈" : "") + TokenFormat.rate(r) + " tok/s"
    }

    private func helpText(_ snap: ContextSnapshot, provider: Provider?) -> String {
        var lines: [String] = []
        if let limit = snap.limit {
            lines.append("Context limit \(TokenFormat.grouped(limit.tokens)) tokens (\(ContextPopover.sourceText(limit.source, serverKind: snap.info?.serverKind)))")
        } else {
            lines.append("The server did not report a context length. Click to enter one.")
        }
        if let kind = snap.info?.serverKind { lines.append("Server: \(kind.displayName)") }
        if case .failed(let message) = snap.reload { lines.append(message) }
        if snap.usage.isEstimated { lines.append("≈ means estimated from the text.") }
        return lines.joined(separator: "\n")
    }

    static func accessibilityText(_ snap: ContextSnapshot) -> String {
        var parts: [String] = []
        if snap.isStreaming, let progress = snap.promptProgress {
            let cached = progress.cached > 0 ? ", \(TokenFormat.grouped(progress.cached)) cached" : ""
            parts.append("Reading prompt \(Int((progress.fraction * 100).rounded(.down))) percent of \(TokenFormat.grouped(progress.total)) tokens\(cached)")
        } else if let r = snap.tokensPerSecond {
            parts.append("Speed \(TokenFormat.rate(r)) tokens per second\(snap.speedIsEstimated ? ", estimated" : "")")
        }
        if case .failed = snap.reload { parts.append("Reload failed") }
        let about = snap.usage.isEstimated ? "about " : ""
        if snap.reload?.isRunning == true {
            parts.append("Reloading model")
        } else if let limit = snap.limit {
            parts.append("Context \(about)\(snap.usage.tokens) of \(limit.tokens) tokens, \(Int((snap.percent ?? 0).rounded())) percent; limit \(ContextPopover.sourceText(limit.source, serverKind: snap.info?.serverKind))")
        } else {
            parts.append("Context \(about)\(snap.usage.tokens) tokens, limit unknown")
        }
        return parts.joined(separator: ". ")
    }
}

/// Icon and title, tightly spaced (the strip's caption size).
private struct StripLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A small progress ring.
struct ContextRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}

/// Liquid Glass on macOS 26 and later, a material elsewhere (like the composer).
private struct StatusCapsuleBackground: ViewModifier {
    private static var usesGlass: Bool {
        #if DEBUG
        if SnapshotHarness.disablesGlass { return false }
        #endif
        return true
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), Self.usesGlass {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
        }
    }
}

// MARK: - Popover

struct ContextPopover: View {
    @Environment(AppState.self) private var appState
    let session: ConversationSession
    let provider: Provider
    let model: String

    // Text drafts, parsed on every keystroke: a formatted TextField would only commit its
    // value on Return, so a button clicked right after typing would act on the old number.
    @ViewState private var manualText = ""
    @ViewState private var reloadText = ""
    @ViewState private var confirmingReload = false

    static func sourceText(_ source: ContextLimitSource, serverKind: InferenceServerKind? = nil) -> String {
        switch source {
        case .server: return "reported by the server"
        case .manual: return "your value"
        case .learned: return serverKind == .strata ? "learned from Strata's error" : "learned from the server's error"
        case .serverMaximum: return "model maximum; the loaded size is unknown"
        }
    }

    var body: some View {
        let (snap, _, _) = ContextSnapshot.make(session: session, appState: appState)
        VStack(alignment: .leading, spacing: 12) {
            header(snap)
            if let limit = snap.limit {
                ProgressView(value: min(snap.usage.percent(of: limit.tokens), 100), total: 100)
                    .tint(snap.tint)
                    .accessibilityLabel("Context used")
            }
            details(snap)
            if snap.info?.serverKind == .strata {
                strataNote(snap)
            }
            // The reload confirmation replaces the manual field, so the popover keeps its height.
            if !confirmingReload {
                Divider()
                manualSection(snap)
            }
            if snap.info?.canSetContextLength == true {
                Divider()
                reloadSection(snap)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            manualText = snap.manual.map(String.init) ?? ""
        }
        // The reload runs on in AppState when the popover closes; its outcome stays until then.
        .onDisappear {
            appState.clearReloadState(provider: provider, model: model)
        }
        #if DEBUG
        .onAppear {
            if SnapshotHarness.showsReloadConfirmation {
                reloadText = "16384"
                confirmingReload = true
            }
        }
        #endif
    }

    private func header(_ snap: ContextSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Context").font(.headline)
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if snap.isProbing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await appState.refreshContextInfo(provider: provider, model: model, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Ask \(provider.name) again")
                .accessibilityLabel("Refresh")
            }
        }
    }

    private func details(_ snap: ContextSnapshot) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("In use").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(snap.usage.tokens > 0
                         ? (snap.usage.isEstimated ? "≈ " : "") + "\(TokenFormat.grouped(snap.usage.tokens)) tokens"
                         + (snap.percent.map { " (\(TokenFormat.percent($0)))" } ?? "")
                         : "Nothing yet")
                    if snap.usage.isEstimated {
                        Text("Estimated from the text; the server's count replaces it after the next reply.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                Text("Limit").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    if let limit = snap.limit {
                        let source = Self.sourceText(limit.source, serverKind: snap.info?.serverKind)
                        Text("\(TokenFormat.grouped(limit.tokens)) tokens")
                        Text(source.prefix(1).uppercased() + source.dropFirst())
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(snap.isProbing ? "Checking…" : "Unknown")
                        if !snap.isProbing && snap.info?.serverKind != .strata {
                            Text("\(provider.name) does not report it. Enter it below if you know it.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let learned = snap.learned, snap.limit?.source != .learned {
                GridRow {
                    Text("Last error").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(TokenFormat.grouped(learned)) tokens")
                        Text(learned == snap.limit?.tokens
                             ? "\(snap.info?.serverKind == .strata ? "Strata's" : "The server's") last overflow error named the same size."
                             : "\(snap.info?.serverKind == .strata ? "Strata's" : "The server's") last overflow error named this size; \(snap.limit?.source == .manual ? "your value, entered after it," : "the reported value") is used instead.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let max = snap.info?.maxContextLength, max != snap.limit?.tokens || snap.limit?.source != .serverMaximum {
                GridRow {
                    Text("Model max").foregroundStyle(.secondary)
                    Text("\(TokenFormat.grouped(max)) tokens")
                }
            }
            if let kind = snap.info?.serverKind {
                GridRow {
                    Text("Server").foregroundStyle(.secondary)
                    Text(kind.displayName + (snap.info?.isLoaded.map { $0 ? " · model loaded" : " · model not loaded" } ?? ""))
                }
            }
            if snap.tokensPerSecond != nil || snap.timeToFirstToken != nil {
                GridRow {
                    Text("Speed").foregroundStyle(.secondary)
                    Text([
                        snap.tokensPerSecond.map { (snap.speedIsEstimated ? "≈" : "") + TokenFormat.rate($0) + " tok/s" },
                        snap.timeToFirstToken.map { TokenFormat.seconds($0) + " to first token" },
                    ].compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let prompt = Self.promptText(snap) {
                GridRow {
                    Text("Prompt").foregroundStyle(.secondary)
                    Text(prompt)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    /// "1,204 read at 850 tok/s · 30,112 cached": where the time to the first token went.
    static func promptText(_ snap: ContextSnapshot) -> String? {
        var parts: [String] = []
        if let read = snap.promptTokensRead {
            parts.append("\(TokenFormat.grouped(read)) read" + (snap.promptTokensPerSecond.map { " at \(TokenFormat.rate($0)) tok/s" } ?? ""))
        } else if let rate = snap.promptTokensPerSecond {
            parts.append("read at \(TokenFormat.rate(rate)) tok/s")
        }
        if let cached = snap.cachedPromptTokens, cached > 0 {
            parts.append("\(TokenFormat.grouped(cached)) cached")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Strata fixes the context length when it starts a model; nothing in its API changes it.
    @ViewBuilder
    private func strataNote(_ snap: ContextSnapshot) -> some View {
        let shared = snap.sharedInstance
            ? " It applies to every provider that reaches this Strata (for example over Tailscale and Cloudflare)."
            : ""
        Text(snap.info?.loadedContextLength != nil
             ? "Strata sets the context length when it starts the model. To use a different size, change it in Strata's setup."
             : snap.manual != nil
             ? "Strata's shared port does not report the context length, so your value below is used.\(shared) If you change the context in Strata's setup, update it here."
             : snap.learned != nil
             ? "Strata's shared port does not report the context length; Parley learned it from Strata's last overflow error and remembers it.\(shared) A value below overrides it."
             : "Strata's shared port does not report the context length. Enter the size chosen in Strata's setup below, or Parley learns it from Strata's first overflow error; it can only be changed in Strata.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func manualSection(_ snap: ContextSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your value").font(.subheadline.weight(.medium))
            HStack {
                TextField("Tokens", text: $manualText, prompt: Text("e.g. 32768"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit(saveManual)
                    .accessibilityLabel("Your context length in tokens")
                Button("Save", action: saveManual)
                    .disabled(TokenFormat.parse(manualText) == nil || TokenFormat.parse(manualText) == snap.manual)
                if snap.manual != nil {
                    Button("Clear") {
                        manualText = ""
                        appState.setManualContextLength(nil, provider: provider, model: model)
                    }
                }
            }
            Text(snap.info?.loadedContextLength != nil && snap.manual != nil
                 ? "The value the server reports takes precedence over yours."
                 : snap.learned != nil || snap.manual != nil
                 ? "Used when the server does not report the loaded context length. A later overflow error naming another size replaces it."
                 : "Used when the server does not report the loaded context length.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveManual() {
        guard let value = TokenFormat.parse(manualText) else { return }
        appState.setManualContextLength(value, provider: provider, model: model)
    }

    @ViewBuilder
    private func reloadSection(_ snap: ContextSnapshot) -> some View {
        let max = snap.info?.maxContextLength
        let loaded = snap.info?.loadedContextLength
        let value = TokenFormat.parse(reloadText) ?? 0
        let busy = snap.reload?.isRunning == true || snap.isProbing || session.isStreaming
        // Reloading to the size already loaded would interrupt other apps for nothing.
        let valid = value >= 1 && value <= (max ?? Int.max) && value != loaded
        VStack(alignment: .leading, spacing: 6) {
            Text("Change on the server").font(.subheadline.weight(.medium))
            if confirmingReload {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Reload \(model) with \(TokenFormat.grouped(value)) tokens?", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .symbolRenderingMode(.multicolor)
                    Text("LM Studio on \(provider.name) unloads the model and loads it again. This affects every app using the model on that server: replies in progress are cut off and the prompt cache is cleared. Loading can take a while; if memory runs out, the model stays unloaded. A model loaded this way may stay in memory until it is unloaded in LM Studio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let key = snap.info?.modelKey, key != model {
                        Text("\(model) is an extra instance of \(key). Every instance is unloaded and one is loaded again; this conversation then uses the new one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { confirmingReload = false }
                            .keyboardShortcut(.cancelAction)
                        // No default-action shortcut: Return must not unload a model for every app.
                        Button("Reload Model", role: .destructive) { reload(value) }
                            .disabled(!valid || busy)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if case .running(let requested) = snap.reload {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reloading with \(TokenFormat.grouped(requested)) tokens… this can take a while.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    TextField("Tokens", text: $reloadText,
                              prompt: Text(loaded.map { "\($0)" } ?? "e.g. 16384"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .accessibilityLabel("New context length in tokens")
                    Button("Reload Model…") { confirmingReload = true }
                        .disabled(!valid || busy)
                }
                Text(max.map { "LM Studio can load this model with up to \(TokenFormat.grouped($0)) tokens." }
                     ?? "LM Studio can reload this model with a different context length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch snap.reload {
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .finished(let note?):
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    private func reload(_ value: Int) {
        confirmingReload = false
        reloadText = ""
        appState.startReload(provider: provider, model: model, contextLength: value, session: session)
    }
}
