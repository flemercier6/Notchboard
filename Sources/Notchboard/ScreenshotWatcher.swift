import CoreServices
import Foundation

/// Watches the macOS screenshot folder for new screenshots and reports each one,
/// so it can be auto-added to the shelf.
///
/// Watching the folder directly (vs a Spotlight query) is deterministic AND
/// triggers the Desktop-folder permission prompt the first time we enumerate it.
@MainActor
final class ScreenshotWatcher {
    var onScreenshot: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var known = Set<String>()
    private let dir: URL

    init() { dir = Self.screenshotLocation() }

    /// The user's configured screenshot location (defaults to ~/Desktop).
    private static func screenshotLocation() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !loc.isEmpty {
            return URL(fileURLWithPath: (loc as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    func start() {
        // Enumerating the folder triggers the TCC prompt (if needed) and sets the
        // baseline so only NEW screenshots are imported.
        known = Set(contents().map(\.path))
        watch()
    }

    private func watch() {
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else {
            // Folder not accessible yet (permission pending) — retry soon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.watch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        source = src
        src.resume()
    }

    private func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    private func scan() {
        for url in contents() where !known.contains(url.path) {
            known.insert(url.path)
            guard isScreenshot(url) else { continue }
            // Small grace delay so the file is fully written before we copy it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self?.onScreenshot?(url)
            }
        }
    }

    private func isScreenshot(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()) else { return false }
        // The reliable signal is the Spotlight screen-capture flag…
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool {
            return flag
        }
        // …falling back to the default localized filename (FR/EN) if not indexed yet.
        let name = url.lastPathComponent.lowercased()
        return name.contains("screenshot") || name.contains("capture")
    }
}
