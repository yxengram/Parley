import AppKit
import SwiftUI
import ParleyCore

/// Attachments inside a sent message: image thumbnails and text-file chips.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(attachments) { a in
                switch a.kind {
                case .image: ImageThumbnail(attachment: a, size: 120)
                case .text: TextFileChip(attachment: a, onRemove: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

struct ImageThumbnail: View {
    let attachment: Attachment
    let size: CGFloat
    var onRemove: (() -> Void)? = nil
    @ViewState private var showPreview = false

    /// The white of the print. Counted inside `size`, so the photo takes the room it always did.
    private var border: CGFloat { size >= 100 ? 7 : 4 }

    var body: some View {
        let image = attachment.data.flatMap { NSImage(data: $0) }
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(Hideout.inkSoft)
                }
            }
            .frame(width: size - border * 2, height: size - border * 2)
            .background(Hideout.paperDeep)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(border)
            .paperCard(attachmentPaper(removable: onRemove != nil), seed: attachment.paperSeed, radius: 7)
            .overlay(alignment: .top) {
                // A photo stuck in the note; the composer's small one has its remove badge there.
                if onRemove == nil {
                    WashiTape(color: Hideout.marigold, width: min(46, size * 0.4), height: 13, angle: -2.5)
                        .offset(y: -6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { showPreview = true }
            .accessibilityElement()
            .accessibilityLabel("Image \(attachment.filename)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showPreview = true }
            .help(attachment.filename)
            .popover(isPresented: $showPreview) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 700, maxHeight: 700)
                        .padding(8)
                        .hideoutSheet()
                }
            }

            if let onRemove {
                RemoveBadge(action: onRemove)
                    .offset(x: 6, y: -6)
            }
        }
    }
}

struct TextFileChip: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?
    @ViewState private var showPreview = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(Hideout.emberText)
            Text(attachment.filename)
                .foregroundStyle(Hideout.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize()
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Hideout.inkSoft)
                }
                .buttonStyle(.plain)
                .help("Remove")
                .accessibilityLabel("Remove Attachment")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .paperCard(attachmentPaper(removable: onRemove != nil), seed: attachment.paperSeed, radius: 9)
        .contentShape(Rectangle())
        .onTapGesture { showPreview = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Preview")) { showPreview = true }
        .help("Click to preview")
        .popover(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 6) {
                Text(attachment.filename).font(.headline)
                ScrollView([.vertical, .horizontal]) {
                    Text(attachment.text ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(width: 560, height: 420)
            .hideoutSheet()
        }
    }
}

/// A sent attachment is cream paper on the room; one in the composer sits on the composer's cream
/// card, so it is cut from the deeper paper.
private func attachmentPaper(removable: Bool) -> Color {
    removable ? Hideout.paperDeep : Hideout.card
}

private extension Attachment {
    /// The same on every launch (`hashValue` is not).
    var paperSeed: Int { Int(id.uuid.0) &* 251 &+ Int(id.uuid.1) }
}

private struct RemoveBadge: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Hideout.card, Hideout.ink)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .help("Remove")
        .accessibilityLabel("Remove Attachment")
    }
}
