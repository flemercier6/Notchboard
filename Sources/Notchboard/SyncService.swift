import AppKit
import Combine
import Foundation
import Supabase

private let kBinaryBucket = "shelf-files"

// Postgres row shapes. Extra columns (created_at/updated_at/…) are ignored on
// decode and defaulted by the DB on insert.
private struct ItemRow: Codable {
    let id: String
    let user_id: String
    let kind: String
    let payload: [String: String]
    let folder_id: String?
    let position: Int
}

private struct FolderRow: Codable {
    let id: String
    let user_id: String
    let name: String
    let kind: String
    let position: Int
}

/// Bidirectional, offline-first sync between the local `ShelfStore` and Supabase.
/// Enabled by an explicit toggle and only while signed in. Uses a persisted "base
/// snapshot" for a 3-way merge so enabling sync uploads local content, other
/// devices pull it, and edits/deletes propagate without clobbering.
///
/// v1 syncs folders + text/color/snippet/note items. Images/files (binary, via
/// Storage) are a follow-up.
@MainActor
final class SyncService: ObservableObject {
    @Published var syncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(syncEnabled, forKey: Self.enabledKey)
            refresh()
        }
    }
    /// Human-readable status surfaced in the account popover (for visibility/debug).
    @Published private(set) var status: String = ""

    private let store: ShelfStore
    private let supabase: SupabaseManager
    private var sessionObserver: AnyCancellable?
    private var running = false
    private var pushTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var reconcileInFlight = false

    private static let enabledKey = "sync.enabled"
    private static var baseURL: URL {
        ShelfPersistence.directory.appendingPathComponent("sync-base.json")
    }

    private struct Base: Codable {
        var userId: String = ""
        var items: [String: String] = [:]   // id -> signature
        var folders: [String: String] = [:]
    }
    private var base = Base()

    var isActive: Bool { syncEnabled && supabase.isSignedIn }

    init(store: ShelfStore, supabase: SupabaseManager) {
        self.store = store
        self.supabase = supabase
        self.syncEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        loadBase()
        store.onLocalChange = { [weak self] in self?.scheduleReconcile(delay: 0.8) }
        sessionObserver = supabase.$session.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // MARK: - Lifecycle

    private func refresh() {
        if isActive { if !running { start() } }
        else { if running { stop() } }
    }

    private func start() {
        running = true
        let uid = supabase.userId?.uuidString ?? ""
        if base.userId != uid { base = Base(userId: uid); saveBase() }   // different account
        scheduleReconcile(delay: 0.1)
        startPolling()
    }

    private func stop() {
        running = false
        pollTask?.cancel(); pollTask = nil
        pushTask?.cancel(); pushTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled, isActive {
                try? await Task.sleep(nanoseconds: 20_000_000_000)   // 20s
                guard !Task.isCancelled, isActive else { break }
                await reconcile()
            }
        }
    }

    private func scheduleReconcile(delay: TimeInterval) {
        guard isActive else { return }
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, isActive else { return }
            await reconcile()
        }
    }

    // MARK: - Reconcile (pull + 3-way merge + apply + push)

    private func reconcile() async {
        guard isActive, !reconcileInFlight, let uid = supabase.userId?.uuidString else { return }
        reconcileInFlight = true
        defer { reconcileInFlight = false }
        status = "Syncing…"

        do {
            let remoteItemRows: [ItemRow] = try await supabase.client
                .from("shelf_items").select().execute().value
            let remoteFolderRows: [FolderRow] = try await supabase.client
                .from("folders").select().execute().value

            // ---- Items 3-way merge ----
            let localSyncable = store.items.filter { itemSignature($0) != nil }
            let localById = Dictionary(localSyncable.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            let remoteById = Dictionary(uniqueKeysWithValues: remoteItemRows.compactMap { row -> (String, ShelfItem)? in
                item(from: row).map { (row.id, $0) }
            })
            let remoteSigById = Dictionary(uniqueKeysWithValues: remoteItemRows.map { ($0.id, signature(forKind: $0.kind, payload: $0.payload, folderId: $0.folder_id)) })

            var resultItems: [ShelfItem] = []   // text items here; binary appended in its own section
            var newItemBase: [String: String] = [:]
            var itemUpserts: [ShelfItem] = []
            var itemDeletes: [String] = []

            let allItemIds = Set(localById.keys).union(remoteById.keys).union(base.items.keys)
            for id in allItemIds {
                let local = localById[id]
                let remote = remoteById[id]
                let lSig = local.flatMap(itemSignature)
                let rSig = remoteSigById[id]
                let bSig = base.items[id]
                switch (local, remote) {
                case let (l?, _?):
                    if lSig == rSig { resultItems.append(l); newItemBase[id] = lSig }
                    else {
                        let localChanged = lSig != bSig
                        let remoteChanged = rSig != bSig
                        if remoteChanged && !localChanged, let r = remote {
                            resultItems.append(r); newItemBase[id] = rSig            // take remote
                        } else {
                            resultItems.append(l); itemUpserts.append(l); newItemBase[id] = lSig // local wins
                        }
                    }
                case let (l?, nil):
                    if bSig == nil || lSig != bSig {
                        resultItems.append(l); itemUpserts.append(l); newItemBase[id] = lSig    // new/edited locally -> push
                    } // else: deleted remotely -> drop
                case let (nil, r?):
                    if bSig == nil {
                        resultItems.append(r); newItemBase[id] = rSig                           // new from another device
                    } else {
                        itemDeletes.append(id)                                                  // deleted locally -> delete remote
                    }
                case (nil, nil):
                    break
                }
            }

            // ---- Folders 3-way merge ----
            let localFolderById = Dictionary(store.folders.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            let remoteFolderById = Dictionary(uniqueKeysWithValues: remoteFolderRows.compactMap { row -> (String, ShelfFolder)? in
                folder(from: row).map { (row.id, $0) }
            })
            let remoteFolderSig = Dictionary(uniqueKeysWithValues: remoteFolderRows.map { ($0.id, folderSignature(name: $0.name, kind: $0.kind)) })

            var resultFolders: [ShelfFolder] = []
            var newFolderBase: [String: String] = [:]
            var folderUpserts: [ShelfFolder] = []
            var folderDeletes: [String] = []

            let allFolderIds = Set(localFolderById.keys).union(remoteFolderById.keys).union(base.folders.keys)
            for id in allFolderIds {
                let local = localFolderById[id]
                let remote = remoteFolderById[id]
                let lSig = local.map(folderSignature)
                let rSig = remoteFolderSig[id]
                let bSig = base.folders[id]
                switch (local, remote) {
                case let (l?, _?):
                    if lSig == rSig { resultFolders.append(l); newFolderBase[id] = lSig }
                    else {
                        let localChanged = lSig != bSig
                        let remoteChanged = rSig != bSig
                        if remoteChanged && !localChanged, let r = remote {
                            resultFolders.append(r); newFolderBase[id] = rSig
                        } else {
                            resultFolders.append(l); folderUpserts.append(l); newFolderBase[id] = lSig
                        }
                    }
                case let (l?, nil):
                    if bSig == nil || lSig != bSig {
                        resultFolders.append(l); folderUpserts.append(l); newFolderBase[id] = lSig
                    }
                case let (nil, r?):
                    if bSig == nil { resultFolders.append(r); newFolderBase[id] = rSig }
                    else { folderDeletes.append(id) }
                case (nil, nil):
                    break
                }
            }

            // ---- Binary items (images / files) via Storage ----
            let localBinaryById = Dictionary(store.items.filter { isBinary($0) }
                .map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            let remoteBinaryById = Dictionary(remoteItemRows.filter { $0.kind == "image" || $0.kind == "file" }
                .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let baseBinaryIds = base.items.filter { $0.value.hasPrefix("image|") || $0.value.hasPrefix("file|") }.map(\.key)

            var newBinaryBase: [String: String] = [:]
            var binaryRowUpserts: [ItemRow] = []
            var binaryRowDeletes: [String] = []
            var binaryStorageDeletes: [String] = []

            for id in Set(localBinaryById.keys).union(remoteBinaryById.keys).union(baseBinaryIds) {
                let local = localBinaryById[id]
                let remote = remoteBinaryById[id]
                let lSig = local.flatMap(binarySignature)
                let rSig = remote.map(binaryRowSignature)
                let bSig = base.items[id]
                switch (local, remote) {
                case let (l?, r?):
                    if lSig == rSig { resultItems.append(l); newBinaryBase[id] = lSig }
                    else if rSig != bSig && lSig == bSig, let updated = applyRemoteMeta(to: l, row: r) {
                        resultItems.append(updated); newBinaryBase[id] = rSig          // metadata moved elsewhere
                    } else {
                        resultItems.append(l); binaryRowUpserts.append(binaryRow(l, userId: uid)); newBinaryBase[id] = lSig
                    }
                case let (l?, nil):
                    if bSig == nil {
                        try await uploadBinary(l, userId: uid)                          // new local binary
                        resultItems.append(l); binaryRowUpserts.append(binaryRow(l, userId: uid)); newBinaryBase[id] = lSig
                    } else if lSig != bSig {
                        resultItems.append(l); binaryRowUpserts.append(binaryRow(l, userId: uid)); newBinaryBase[id] = lSig
                    } // else: deleted remotely -> drop (local file pruned on save)
                case let (nil, r?):
                    if bSig == nil {
                        if let item = try await downloadBinary(r, userId: uid) {         // new from another device
                            resultItems.append(item); newBinaryBase[id] = rSig
                        }
                    } else {                                                            // deleted locally -> delete remote
                        binaryRowDeletes.append(id)
                        binaryStorageDeletes.append(storagePath(uid: uid, id: id, ext: r.payload["ext"] ?? "bin"))
                    }
                case (nil, nil):
                    break
                }
            }

            // ---- Apply locally (only if something changed, to avoid UI churn) ----
            resultItems.sort { $0.createdAt < $1.createdAt }
            if !sameItems(resultItems, store.items) || !sameFolders(resultFolders, store.folders) {
                store.applyRemote(folders: resultFolders, items: resultItems)
            }

            // ---- Push diffs to Supabase ----
            if !folderUpserts.isEmpty {
                try await supabase.client.from("folders").upsert(folderUpserts.map { folderRow($0, userId: uid) }).execute()
            }
            let allItemUpserts = itemUpserts.compactMap { itemRow($0, userId: uid) } + binaryRowUpserts
            if !allItemUpserts.isEmpty {
                try await supabase.client.from("shelf_items").upsert(allItemUpserts).execute()
            }
            let allItemDeletes = itemDeletes + binaryRowDeletes
            if !allItemDeletes.isEmpty {
                try await supabase.client.from("shelf_items").delete().in("id", values: allItemDeletes).execute()
            }
            if !binaryStorageDeletes.isEmpty {
                _ = try? await supabase.client.storage.from(kBinaryBucket).remove(paths: binaryStorageDeletes)
            }
            if !folderDeletes.isEmpty {
                try await supabase.client.from("folders").delete().in("id", values: folderDeletes).execute()
            }

            base.items = newItemBase.merging(newBinaryBase) { _, b in b }
            base.folders = newFolderBase
            base.userId = uid
            saveBase()

            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            status = "✓ \(f.string(from: Date())) — text \(localSyncable.count), binary \(localBinaryById.count); "
                + "pushed \(itemUpserts.count + binaryRowUpserts.count); "
                + "cloud \(newItemBase.count + newBinaryBase.count); folders \(resultFolders.count)"
        } catch {
            status = "⚠️ \(String(describing: error).prefix(300))"
        }
    }

    // MARK: - Mapping & signatures

    /// nil signature => not syncable in v1 (image/file).
    private func itemSignature(_ item: ShelfItem) -> String? {
        guard let payload = payloadDict(item) else { return nil }
        return signature(forKind: item.payload.kind.rawValue, payload: payload, folderId: item.folderId?.uuidString)
    }

    private func signature(forKind kind: String, payload: [String: String], folderId: String?) -> String {
        let p = payload.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(kind)|\(folderId ?? "-")|\(p)"
    }

    private func folderSignature(_ f: ShelfFolder) -> String { folderSignature(name: f.name, kind: f.kind.rawValue) }
    private func folderSignature(name: String, kind: String) -> String { "\(kind)|\(name)" }

    private func payloadDict(_ item: ShelfItem) -> [String: String]? {
        switch item.payload {
        case .text(let s): return ["text": s]
        case .color(let hex): return ["hex": hex]
        case .snippet(let t, let r): return ["trigger": t, "replacement": r]
        case .note(let c): return ["content": c]
        case .image, .file: return nil   // binary — not synced in v1
        }
    }

    private func item(from row: ItemRow) -> ShelfItem? {
        guard let id = UUID(uuidString: row.id) else { return nil }
        let folderId = row.folder_id.flatMap(UUID.init(uuidString:))
        let payload: ShelfPayload
        switch row.kind {
        case "text": payload = .text(row.payload["text"] ?? "")
        case "color": payload = .color(row.payload["hex"] ?? "#")
        case "snippet": payload = .snippet(trigger: row.payload["trigger"] ?? "", replacement: row.payload["replacement"] ?? "")
        case "note": payload = .note(row.payload["content"] ?? "")
        default: return nil
        }
        return ShelfItem(id: id, payload: payload, folderId: folderId)
    }

    private func itemRow(_ item: ShelfItem, userId: String) -> ItemRow? {
        guard let payload = payloadDict(item) else { return nil }
        return ItemRow(id: item.id.uuidString, user_id: userId, kind: item.payload.kind.rawValue,
                       payload: payload, folder_id: item.folderId?.uuidString, position: 0)
    }

    private func folder(from row: FolderRow) -> ShelfFolder? {
        guard let id = UUID(uuidString: row.id) else { return nil }
        return ShelfFolder(id: id, name: row.name, kind: ShelfPayload.Kind(rawValue: row.kind) ?? .text)
    }

    private func folderRow(_ f: ShelfFolder, userId: String) -> FolderRow {
        FolderRow(id: f.id.uuidString, user_id: userId, name: f.name, kind: f.kind.rawValue, position: 0)
    }

    // MARK: - Binary (image/file) helpers — content lives in Supabase Storage

    private func isBinary(_ item: ShelfItem) -> Bool {
        switch item.payload { case .image, .file: return true; default: return false }
    }

    private func binaryURLAndExt(_ item: ShelfItem) -> (url: URL, ext: String)? {
        switch item.payload {
        case .image(let url, _, _): return (url, url.pathExtension.isEmpty ? "img" : url.pathExtension)
        case .file(let url, _): return (url, url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        default: return nil
        }
    }

    private func binarySignature(_ item: ShelfItem) -> String? {
        let folder = item.folderId?.uuidString ?? "-"
        switch item.payload {
        case .image(let url, let name, _): return "image|\(folder)|\(name)|\(url.pathExtension)"
        case .file(let url, let name): return "file|\(folder)|\(name)|\(url.pathExtension)"
        default: return nil
        }
    }

    private func binaryRowSignature(_ row: ItemRow) -> String {
        "\(row.kind)|\(row.folder_id ?? "-")|\(row.payload["name"] ?? "")|\(row.payload["ext"] ?? "")"
    }

    private func binaryRow(_ item: ShelfItem, userId: String) -> ItemRow {
        let name: String, ext: String
        switch item.payload {
        case .image(let url, let n, _): name = n; ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        case .file(let url, let n): name = n; ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        default: name = ""; ext = "bin"
        }
        return ItemRow(id: item.id.uuidString, user_id: userId, kind: item.payload.kind.rawValue,
                       payload: ["name": name, "ext": ext], folder_id: item.folderId?.uuidString, position: 0)
    }

    // Lowercased: the Storage RLS policy compares the path's first folder to
    // auth.uid()::text (lowercase). Swift's UUID.uuidString is uppercase, so we
    // normalize uid AND id to keep upload/download paths consistent and authorized.
    private func storagePath(uid: String, id: String, ext: String) -> String {
        "\(uid.lowercased())/\(id.lowercased()).\(ext)"
    }

    private func uploadBinary(_ item: ShelfItem, userId uid: String) async throws {
        guard let (url, ext) = binaryURLAndExt(item) else { return }
        let data = try Data(contentsOf: url)
        let path = storagePath(uid: uid, id: item.id.uuidString, ext: ext)
        try await supabase.client.storage.from(kBinaryBucket)
            .upload(path, data: data, options: FileOptions(upsert: true))
    }

    private func downloadBinary(_ row: ItemRow, userId uid: String) async throws -> ShelfItem? {
        guard let id = UUID(uuidString: row.id) else { return nil }
        let name = row.payload["name"] ?? "file"
        let ext = row.payload["ext"] ?? "bin"
        let path = storagePath(uid: uid, id: row.id, ext: ext)
        let data = try await supabase.client.storage.from(kBinaryBucket).download(path: path)
        let folderId = row.folder_id.flatMap(UUID.init(uuidString:))
        if row.kind == "image" {
            guard let url = ShelfPersistence.storeImageData(data, id: id, ext: ext),
                  let img = NSImage(contentsOf: url) else { return nil }
            return ShelfItem(id: id, payload: .image(url: url, name: name, image: img), folderId: folderId)
        } else {
            guard let url = ShelfPersistence.storeFileData(data, id: id, name: name) else { return nil }
            return ShelfItem(id: id, payload: .file(url: url, name: name), folderId: folderId)
        }
    }

    /// Update a local binary item's folder/name from a remote row (binary stays local).
    private func applyRemoteMeta(to item: ShelfItem, row: ItemRow) -> ShelfItem? {
        let folderId = row.folder_id.flatMap(UUID.init(uuidString:))
        let name = row.payload["name"] ?? ""
        switch item.payload {
        case .image(let url, _, let img):
            return ShelfItem(id: item.id, payload: .image(url: url, name: name, image: img), createdAt: item.createdAt, folderId: folderId)
        case .file(let url, _):
            return ShelfItem(id: item.id, payload: .file(url: url, name: name), createdAt: item.createdAt, folderId: folderId)
        default: return nil
        }
    }

    private func sameItems(_ a: [ShelfItem], _ b: [ShelfItem]) -> Bool {
        guard a.count == b.count else { return false }
        func sig(_ i: ShelfItem) -> String { itemSignature(i) ?? binarySignature(i) ?? "" }
        for (x, y) in zip(a, b) where x.id != y.id || sig(x) != sig(y) { return false }
        return true
    }
    private func sameFolders(_ a: [ShelfFolder], _ b: [ShelfFolder]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where x.id != y.id || folderSignature(x) != folderSignature(y) { return false }
        return true
    }

    // MARK: - Base snapshot persistence

    private func loadBase() {
        guard let data = try? Data(contentsOf: Self.baseURL),
              let decoded = try? JSONDecoder().decode(Base.self, from: data) else { return }
        base = decoded
    }
    private func saveBase() {
        guard let data = try? JSONEncoder().encode(base) else { return }
        try? data.write(to: Self.baseURL)
    }
}
