import AppKit

/// The currently-playing track from a scriptable player (Spotify / Apple Music).
struct NowPlayingTrack: Equatable {
    enum Source: String { case spotify = "Spotify", music = "Music" }
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var source: Source
    var artworkURL: URL?
}

/// Polls Spotify and Apple Music via AppleScript for the now-playing track and
/// sends transport commands. Requires the Automation permission (TCC).
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var track: NowPlayingTrack?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.notchboard.nowplaying")
    private var artworkCache: [String: URL] = [:]

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }

    private func control(_ command: String) {
        guard let source = track?.source else { return }
        let script = "tell application \"\(source.rawValue)\" to \(command)"
        queue.async { _ = Self.run(script) }
        // Reflect the new state quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.poll() }
    }

    private func poll() {
        queue.async { [weak self] in
            let result = Self.fetch()
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    private func apply(_ result: NowPlayingTrack?) {
        guard var result else { track = nil; return }
        // Apple Music gives no artwork URL — resolve one from the iTunes Search API.
        if result.artworkURL == nil {
            let key = "\(result.artist) — \(result.title)"
            if let cached = artworkCache[key] {
                result.artworkURL = cached
            } else {
                track = result
                Task { @MainActor in
                    if let url = await Self.iTunesArtwork(artist: result.artist, title: result.title) {
                        artworkCache[key] = url
                        if track?.title == result.title, track?.artist == result.artist {
                            track?.artworkURL = url
                        }
                    }
                }
                return
            }
        }
        track = result
    }

    // MARK: - AppleScript

    nonisolated private static func fetch() -> NowPlayingTrack? {
        let spotify = fetchApp(.spotify)
        if spotify?.isPlaying == true { return spotify }
        let music = fetchApp(.music)
        if music?.isPlaying == true { return music }
        return spotify ?? music   // a paused track, if any
    }

    nonisolated private static func fetchApp(_ source: NowPlayingTrack.Source) -> NowPlayingTrack? {
        let app = source.rawValue
        let artworkLine = source == .spotify
            ? " & \"\\n\" & (artwork url of current track)"
            : ""
        let script = """
        if application "\(app)" is running then
            tell application "\(app)"
                if player state is stopped then return "stopped"
                return (player state as string) & "\\n" & (name of current track) & "\\n" & (artist of current track) & "\\n" & (album of current track)\(artworkLine)
            end tell
        else
            return "notrunning"
        end if
        """
        guard let output = run(script), output != "notrunning", output != "stopped" else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }
        let artworkURL = parts.count >= 5 ? URL(string: parts[4]) : nil
        return NowPlayingTrack(
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            isPlaying: parts[0] == "playing",
            source: source,
            artworkURL: artworkURL
        )
    }

    nonisolated private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor.stringValue
    }

    nonisolated private static func iTunesArtwork(artist: String, title: String) async -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Response: Decodable {
            struct Item: Decodable { let artworkUrl100: String? }
            let results: [Item]
        }
        guard let art = (try? JSONDecoder().decode(Response.self, from: data))?.results.first?.artworkUrl100
        else { return nil }
        return URL(string: art.replacingOccurrences(of: "100x100", with: "300x300"))
    }
}
