import AppKit
import SwiftUI
import ParleyCore

/// Attachments inside a sent message: image thumbnails and text-file chips.
struct AttachmentStrip: View {
    let attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    switch a.kind {
                    case .image: ImageThumbnail(attachment: a, size: 120)
                    case .text: TextFileChip(attachment: a, onRemove: nil)
                    }
                }
            }
        }
    }
}

struct ImageThumbnail: View {
    let attachment: Attachment
    let size: CGFloat
    var onRemove: (() -> Void)? = nil
    @ViewState private var showPreview = false

    var body: some View {
        let image = attachment.data.flatMap { NSImage(data: $0) }
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .onTapGesture { showPreview = true }
            .help(attachment.filename)
            .popover(isPresented: $showPreview) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 700, maxHeight: 700)
                        .padding(8)
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
            Text(attachment.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { showPreview = true }
        .help("Click to preview")
        .popover(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 6) {
                Text(attachment.filename).font(.headline)
                ScrollView([.vertical, .horizontal]) {
                    Text(attachment.text ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(width: 560, height: 420)
        }
    }
}

private struct RemoveBadge: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.7))
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}
