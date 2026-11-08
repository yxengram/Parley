import SwiftUI

/// A link the user clicked, waiting for their answer. Only a link Parley may open can exist as one:
/// http or https, with a host that means to a browser what it says on the sheet.
struct PendingLink: Identifiable {
    let id = UUID()
    let url: URL
    let host: String

    init?(_ link: URL) {
        let url = Self.real(link)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: true), Self.readsAsItResolves(host),
              // An address the inert form cannot carry would be a link that does nothing.
              URL(string: url.absoluteString) != nil else { return nil }
        self.url = url
        self.host = ToolDisplay.address(host)
    }

    /// False for a host a browser reads differently. It decodes percent-encoding, so
    /// `good.example%2Eevil.net` belongs to evil.net. It takes a host ending in a number for an IPv4
    /// address in any base, so `010.010.010.010`, which reads as a LAN address, is 8.8.8.8. A host
    /// with neither, such as the missing one in `https:evil.example`, leaves the browser guessing.
    private static func readsAsItResolves(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains("%") else { return false }
        if host.contains(":") { return true } // IPv6
        let labels = host.lowercased().split(separator: ".")
        guard let last = labels.last else { return false }
        let endsInNumber = last.allSatisfy { $0.isASCII && $0.isNumber }
            || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
        guard endsInNumber else { return true }
        return labels.count == 4 && labels.allSatisfy { label in
            Int(label).map { (0...255).contains($0) && String($0) == label } ?? false
        }
    }

    /// Rendered text holds this form of a link, never the real one. Whatever the system offers on a
    /// link beside a click (a context menu differs by macOS version) may not go through the app's
    /// OpenURLAction, and an address nothing can open gets nowhere without it.
    static func inert(_ url: URL) -> URL? {
        URL(string: inertPrefix + Data(url.absoluteString.utf8).base64EncodedString())
    }

    private static let inertPrefix = "parley-link:"

    private static func real(_ link: URL) -> URL {
        guard link.absoluteString.hasPrefix(inertPrefix),
              let data = Data(base64Encoded: String(link.absoluteString.dropFirst(inertPrefix.count))),
              let address = String(data: data, encoding: .utf8),
              let url = URL(string: address) else { return link }
        return url
    }

    /// The full destination as it will open. Punycode and percent-encoding stay: read back as
    /// letters they would bring the lookalikes back.
    var address: String { ToolDisplay.address(url.absoluteString) }

    var hasHiddenCharacters: Bool { address != url.absoluteString }
}

/// A link in model text can carry the conversation in its address, and its text can say anything, so
/// a click shows where it really goes and asks. No keyboard shortcut on Open: this is the last step
/// before data leaves the Mac, so it takes a deliberate click.
struct LinkConfirmationSheet: View {
    let link: PendingLink
    let open: () -> Void
    let cancel: () -> Void

    /// False for a moment after the sheet appears, so the second click of a double-click on the link
    /// cannot land on Open.
    @ViewState private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                DecisionHeading(title: Text("Open this link in your browser?"))
                Text("Opening sends the whole address to this site, including anything a model put in it.")
                    .font(.callout)
                    .foregroundStyle(Hideout.ink)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Site")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Hideout.inkSoft)
                    // The end of a host is the part that says whose it is.
                    Text(verbatim: link.host)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .fontDesign(.monospaced)
                        .foregroundStyle(Hideout.ink)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                ToolTextBlock(title: "Address", text: link.address, maxHeight: 200)
                if link.hasHiddenCharacters {
                    Label("The address contains hidden or right-to-left characters, shown here as \\u{…}.", systemImage: "exclamationmark.triangle.fill")
                        .safetyNotice(.caution)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .noticeCard(fill: Hideout.attentionWash, edge: Hideout.attention)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(TagButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .buttonStyle(TagButtonStyle(kind: .primary))
                    .disabled(!armed)
            }
        }
        .task(id: link.id) {
            armed = false
            try? await Task.sleep(nanoseconds: UInt64(ToolApprovalCard.armDelay * 1_000_000_000))
            armed = true
        }
        .padding(20)
        .frame(width: 480)
    }
}

// Private on purpose: other surfaces define their own helpers, and these must not collide.
private enum SafetyTone { case caution, danger }

private extension View {
    /// A warning or an error on its own flat strip. Exact wording, no decoration.
    func safetyNotice(_ tone: SafetyTone) -> some View {
        let edge = tone == .danger ? Hideout.danger : Hideout.caution
        return self
            .font(.callout.weight(.medium))
            .foregroundStyle(edge)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .noticeCard(fill: tone == .danger ? Hideout.dangerWash : Hideout.cautionWash, edge: edge, radius: 8)
    }
}


/// The title of something that needs a decision: plain and strong, never lettered.
private struct DecisionHeading: View {
    let title: Text

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Hideout.paper)
                .frame(width: 26, height: 26)
                .background(Hideout.attention, in: Circle())
                .accessibilityHidden(true)
            title
                .font(Hideout.title(16))
                .foregroundStyle(Hideout.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
