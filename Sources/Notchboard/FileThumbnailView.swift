import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Generates and caches real QuickLook thumbnails (PDF first page, video frame,
/// document preview, …) keyed by file path. Falls back to the type icon.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, maxSize: CGSize) async -> NSImage? {
        let key = "\(url.path)|\(Int(maxSize.width))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: maxSize, scale: scale,
            representationTypes: .thumbnail)

        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
                guard let rep else { cont.resume(returning: nil); return }
                let image = rep.nsImage
                self?.cache.setObject(image, forKey: key)
                cont.resume(returning: image)
            }
        }
    }
}

/// A file tile that shows the document's real preview (or the type icon while it
/// loads / if no preview exists), with the file name underneath.
struct FileThumbnailView: View {
    let url: URL
    let name: String
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url.path) {
            thumb = await ThumbnailCache.shared.thumbnail(
                for: url, maxSize: CGSize(width: 200, height: 150))
        }
    }
}
