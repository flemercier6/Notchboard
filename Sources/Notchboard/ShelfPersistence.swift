import AppKit

/// On-disk representation of one shelf item.
private struct StoredEntry: Codable {
    let id: UUID
    let kind: String          // "text" | "image" | "file"
    let createdAt: Date
    let text: String?
    let imageFile: String?    // filename inside the images directory
    let fileName: String?     // filename inside the files directory
    let displayName: String?  // original file name, shown to the user
    let folderId: UUID?       // owning folder, if any
}

private struct StoredFolder: Codable {
    let id: UUID
    let name: String
    let kind: String?   // content type; nil for folders saved before typing existed
}

/// Top-level index. Stored as an object so folders and items live together;
/// older builds wrote a bare `[StoredEntry]` array, which `load` still reads.
private struct StoredIndex: Codable {
    let folders: [StoredFolder]
    let items: [StoredEntry]
}

/// Loads and saves the shelf to Application Support. Text lives in the index,
/// images are written as PNG files referenced by the index.
enum ShelfPersistence {
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = base.appendingPathComponent("Notchboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var imagesDirectory: URL {
        let dir = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var filesDirectory: URL {
        let dir = directory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var indexURL: URL {
        directory.appendingPathComponent("index.json")
    }

    /// Copy a dropped image file into storage, preserving its original format
    /// (extension and bytes). Returns the stored URL.
    static func importImageFile(_ source: URL, id: UUID) -> URL? {
        let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension
        let destination = imagesDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Store an image with no backing file as PNG. Returns the stored URL.
    static func storeImageAsPNG(_ image: NSImage, id: UUID) -> URL? {
        guard let png = image.pngData() else { return nil }
        let destination = imagesDirectory.appendingPathComponent("\(id.uuidString).png")
        do {
            try png.write(to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Copy a dropped file into local storage; returns the stored URL.
    /// The stored name embeds the item id so distinct items never collide.
    static func importFile(_ source: URL, id: UUID) -> URL? {
        let destination = filesDirectory
            .appendingPathComponent("\(id.uuidString)__\(source.lastPathComponent)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Write image bytes downloaded from sync to a local file with a known id.
    static func storeImageData(_ data: Data, id: UUID, ext: String) -> URL? {
        let e = ext.isEmpty ? "img" : ext
        let destination = imagesDirectory.appendingPathComponent("\(id.uuidString).\(e)")
        do { try data.write(to: destination); return destination } catch { return nil }
    }

    /// Write file bytes downloaded from sync to a local file with a known id.
    static func storeFileData(_ data: Data, id: UUID, name: String) -> URL? {
        let destination = filesDirectory.appendingPathComponent("\(id.uuidString)__\(name)")
        do { try data.write(to: destination); return destination } catch { return nil }
    }

    static func load() -> (folders: [ShelfFolder], items: [ShelfItem]) {
        guard let data = try? Data(contentsOf: indexURL) else {
            return ([], [])
        }

        let decoder = JSONDecoder()
        let storedFolders: [StoredFolder]
        let entries: [StoredEntry]
        if let index = try? decoder.decode(StoredIndex.self, from: data) {
            storedFolders = index.folders
            entries = index.items
        } else if let legacy = try? decoder.decode([StoredEntry].self, from: data) {
            storedFolders = []
            entries = legacy
        } else {
            return ([], [])
        }

        let folders = storedFolders.map {
            ShelfFolder(id: $0.id, name: $0.name, kind: $0.kind.flatMap(ShelfPayload.Kind.init(rawValue:)) ?? .text)
        }
        let folderIds = Set(folders.map(\.id))

        let items: [ShelfItem] = entries.compactMap { entry in
            // Drop a stale folder reference if that folder no longer exists.
            let folderId = entry.folderId.flatMap { folderIds.contains($0) ? $0 : nil }
            switch entry.kind {
            case "text":
                guard let text = entry.text else { return nil }
                return ShelfItem(id: entry.id, payload: .text(text), createdAt: entry.createdAt, folderId: folderId)
            case "image":
                guard let file = entry.imageFile else { return nil }
                let url = imagesDirectory.appendingPathComponent(file)
                guard let image = NSImage(contentsOf: url) else { return nil }
                let name = entry.displayName ?? url.lastPathComponent
                return ShelfItem(id: entry.id, payload: .image(url: url, name: name, image: image), createdAt: entry.createdAt, folderId: folderId)
            case "file":
                guard let file = entry.fileName else { return nil }
                let url = filesDirectory.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let name = entry.displayName ?? url.lastPathComponent
                return ShelfItem(id: entry.id, payload: .file(url: url, name: name), createdAt: entry.createdAt, folderId: folderId)
            case "color":
                guard let hex = entry.text else { return nil }
                return ShelfItem(id: entry.id, payload: .color(hex), createdAt: entry.createdAt, folderId: folderId)
            case "snippet":
                let trigger = entry.displayName ?? ""
                let replacement = entry.text ?? ""
                guard !trigger.isEmpty else { return nil }
                return ShelfItem(id: entry.id, payload: .snippet(trigger: trigger, replacement: replacement), createdAt: entry.createdAt, folderId: folderId)
            case "note":
                return ShelfItem(id: entry.id, payload: .note(entry.text ?? ""), createdAt: entry.createdAt, folderId: folderId)
            default:
                return nil
            }
        }

        return (folders, items)
    }

    static func save(folders: [ShelfFolder], items: [ShelfItem]) {
        var entries: [StoredEntry] = []
        var keepImages = Set<String>()
        var keepFiles = Set<String>()

        for item in items {
            switch item.payload {
            case .text(let text):
                entries.append(StoredEntry(
                    id: item.id, kind: "text", createdAt: item.createdAt,
                    text: text, imageFile: nil, fileName: nil, displayName: nil,
                    folderId: item.folderId
                ))

            case .image(let url, let name, _):
                // The image file was already written to storage at add time
                // (original format preserved), so just reference it.
                let filename = url.lastPathComponent
                keepImages.insert(filename)
                entries.append(StoredEntry(
                    id: item.id, kind: "image", createdAt: item.createdAt,
                    text: nil, imageFile: filename, fileName: nil, displayName: name,
                    folderId: item.folderId
                ))

            case .file(let url, let name):
                // The file was already copied into storage at import time.
                let filename = url.lastPathComponent
                keepFiles.insert(filename)
                entries.append(StoredEntry(
                    id: item.id, kind: "file", createdAt: item.createdAt,
                    text: nil, imageFile: nil, fileName: filename, displayName: name,
                    folderId: item.folderId
                ))

            case .color(let hex):
                entries.append(StoredEntry(
                    id: item.id, kind: "color", createdAt: item.createdAt,
                    text: hex, imageFile: nil, fileName: nil, displayName: nil,
                    folderId: item.folderId
                ))

            case .snippet(let trigger, let replacement):
                entries.append(StoredEntry(
                    id: item.id, kind: "snippet", createdAt: item.createdAt,
                    text: replacement, imageFile: nil, fileName: nil, displayName: trigger,
                    folderId: item.folderId
                ))

            case .note(let content):
                entries.append(StoredEntry(
                    id: item.id, kind: "note", createdAt: item.createdAt,
                    text: content, imageFile: nil, fileName: nil, displayName: nil,
                    folderId: item.folderId
                ))
            }
        }

        let index = StoredIndex(
            folders: folders.map { StoredFolder(id: $0.id, name: $0.name, kind: $0.kind.rawValue) },
            items: entries
        )
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL)
        }

        prune(directory: imagesDirectory, keeping: keepImages)
        prune(directory: filesDirectory, keeping: keepFiles)
    }

    /// Remove files in a directory that are no longer referenced by any item.
    private static func prune(directory: URL, keeping: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for file in files where !keeping.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

extension NSImage {
    /// PNG encoding for on-disk storage.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
