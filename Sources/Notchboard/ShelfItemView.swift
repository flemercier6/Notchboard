import SwiftUI
import UniformTypeIdentifiers

/// Holds the id of the tile currently being dragged. A reference type so it can
/// be set in `onDrag` WITHOUT triggering a SwiftUI re-render at drag start.
final class ReorderState {
    var draggedId: UUID?
}

/// A single tile on the shelf. Tap to copy to the clipboard, drag to drop
/// elsewhere, hover to reveal the remove button.
struct ShelfItemView: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    @ObservedObject var viewModel: NotchViewModel
    let reorder: ReorderState
    var onEdit: () -> Void = {}

    @State private var isHovering = false
    @State private var didCopy = false

    // Slightly wider than tall.
    private let tileWidth: CGFloat = 130
    private let tileHeight: CGFloat = 104

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: tileWidth, height: tileHeight)
                .background(FrostedBackground(cornerRadius: 14))
                // On hover, darken the top so the action buttons stand out.
                .overlay {
                    if isHovering {
                        LinearGradient(
                            colors: [.black.opacity(0.6), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            // Editable hex code, layered ABOVE the hover gradient.
            if case .color(let hex) = item.payload {
                ColorHexField(
                    hex: Binding(
                        get: { hex },
                        set: { store.setColorHex(item.id, $0) }
                    ),
                    shouldFocus: viewModel.editingColorId == item.id,
                    onBeginEditing: { viewModel.editingColorId = item.id },
                    onCommit: { viewModel.editingColorId = nil }
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(width: tileWidth, height: tileHeight, alignment: .topLeading)
            }

            topOverlay

            if didCopy {
                copiedBadge
            }
        }
        // Pin the tile's size and hit region to exactly one tile, so nothing can
        // overflow into a neighbour's hover/click area.
        .frame(width: tileWidth, height: tileHeight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHovering)
        .onTapGesture { activate() }
        .onDrag {
            reorder.draggedId = item.id
            return dragProvider()
        }
        .help(tooltip)
    }

    /// Click behaviour per item type: colors copy; snippets/notes open their
    /// editor; images/videos/files open the item. (Everything is still draggable.)
    private func activate() {
        switch item.payload {
        case .color:
            store.copyToClipboard(item)
            flashCopied()
        case .snippet, .note:
            onEdit()
        case .image(let url, _, _):
            NSWorkspace.shared.open(url)
        case .file(let url, _):
            NSWorkspace.shared.open(url)
        case .text:
            // No natural "open" for raw text — left as a no-op (still draggable).
            break
        }
    }

    /// Hover button to file this item into a folder (or remove it from one).
    private var moveMenu: some View {
        Menu {
            ForEach(store.folders) { folder in
                Button {
                    store.moveItem(item.id, toFolder: folder.id)
                } label: {
                    if item.folderId == folder.id {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if item.folderId != nil {
                Divider()
                Button("Remove from folder") {
                    store.moveItem(item.id, toFolder: nil)
                }
            }
        } label: {
            Image(systemName: "folder.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var topOverlay: some View {
        Group {
            if isHovering {
                HStack(alignment: .center, spacing: 6) {
                    if let imageFileName {
                        Text(imageFileName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(imageFileName)
                    } else {
                        Spacer(minLength: 0)
                    }

                actionButtons
                    .transition(.opacity)
                }
            }
        }
        .padding(6)
        .frame(width: tileWidth, height: tileHeight, alignment: .top)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if item.payload.kind == .snippet || item.payload.kind == .note {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }
            if !store.folders.isEmpty {
                moveMenu
            }
            Button {
                store.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
    }

    private var imageFileName: String? {
        if case .image(_, let name, _) = item.payload {
            return name
        }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch item.payload {
        case .text(let string):
            Text(string)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image(_, _, let image):
            // Wrap in a fixed-size clear container + clip so the scaledToFill
            // overflow can NEVER leak into the tile's layout / hit-testing
            // (otherwise neighbouring tiles overlap and steal the hover/click).
            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                }
                .clipped()
        case .file(let url, let name):
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .color(let hex):
            // Just the color fill here; the editable code is layered above the
            // hover gradient in the body (so it stays readable/clickable).
            (Color(hex: hex) ?? Color.white.opacity(0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .snippet(let trigger, let replacement):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "text.badge.plus").font(.system(size: 9))
                    Text(trigger)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                Text(replacement)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .note(let content):
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "note.text").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Empty note")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    Text(markdownPreview(content))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Renders markdown inline (bold/italic/links) for the tile preview, falling
    /// back to plain text.
    private func markdownPreview(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
    }

    private var copiedBadge: some View {
        Text("Copied")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.35))
    }

    private var tooltip: String {
        switch item.payload {
        case .text(let string):
            return String(string.prefix(120))
        case .image(_, let name, _):
            return name
        case .file(_, let name):
            return name
        case .color(let hex):
            return hex
        case .snippet(let trigger, let replacement):
            return "\(trigger) → \(replacement)"
        case .note(let content):
            return String(content.prefix(120))
        }
    }

    private func dragProvider() -> NSItemProvider {
        let provider: NSItemProvider
        switch item.payload {
        case .text(let string):
            provider = NSItemProvider(object: string as NSString)
        case .image(let url, let name, _):
            // Vend the original image file so apps (design tools, etc.) receive it
            // in its native format (PNG/JPEG/…) instead of a converted TIFF, and
            // keep its original name.
            provider = fileProvider(url: url, name: name)
        case .file(let url, let name):
            provider = fileProvider(url: url, name: name)
        case .color(let hex):
            provider = NSItemProvider(object: hex as NSString)
        case .snippet(_, let replacement):
            provider = NSItemProvider(object: replacement as NSString)
        case .note(let content):
            provider = NSItemProvider(object: content as NSString)
        }

        // Also carry the item id so the tile can be dropped onto a folder pill
        // to file it. External apps simply ignore this extra representation.
        let id = item.id
        provider.registerDataRepresentation(
            forTypeIdentifier: NotchView.itemType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// A drag provider that exports the real file under its original name.
    private func fileProvider(url: URL, name: String) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        provider.suggestedName = (name as NSString).deletingPathExtension
        return provider
    }

    private func flashCopied() {
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            didCopy = false
        }
    }
}
