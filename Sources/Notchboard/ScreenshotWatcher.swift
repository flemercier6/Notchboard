import Foundation

/// Watches Spotlight for newly-taken screenshots (wherever macOS saves them) and
/// reports each new one, so it can be auto-added to the shelf. Uses the
/// `kMDItemIsScreenCapture` metadata flag — language- and location-independent.
@MainActor
final class ScreenshotWatcher: NSObject {
    /// Called on the main actor with the URL of each new screenshot.
    var onScreenshot: ((URL) -> Void)?

    private let query = NSMetadataQuery()
    private var seen = Set<String>()
    private var baselined = false

    func start() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        NotificationCenter.default.addObserver(
            self, selector: #selector(gathered),
            name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updated),
            name: .NSMetadataQueryDidUpdate, object: query)
        query.start()
    }

    /// Initial pass: remember every existing screenshot so we only import NEW ones.
    @objc private func gathered(_ note: Notification) {
        query.disableUpdates()
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                seen.insert(path)
            }
        }
        baselined = true
        query.enableUpdates()
    }

    /// A screenshot was just taken (or its metadata finalized) → import it.
    @objc private func updated(_ note: Notification) {
        guard baselined else { return }
        let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
        let changed = (note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? []
        for item in added + changed {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !seen.contains(path),
                  FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(path)
            onScreenshot?(URL(fileURLWithPath: path))
        }
    }
}
