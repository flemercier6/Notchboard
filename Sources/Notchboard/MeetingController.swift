import Combine
import Foundation

/// Orchestrates the meeting feature: detect (mic active) → offer to record →
/// record two streams → transcribe both via Deepgram → merge into a labeled
/// transcript → summarize via OpenAI → save the result as a Note.
@MainActor
final class MeetingController: ObservableObject {
    enum State: Equatable {
        case idle
        case prompt          // a meeting was detected; offer to record
        case recording
        case processing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Int = 0
    /// Last 4 audio levels (0…1) for the mini visualizer, oldest → newest.
    @Published private(set) var levels: [Float] = [0, 0, 0, 0]
    private var lastLevelPush = Date.distantPast

    private let detector: MeetingDetector
    private let store: ShelfStore
    private let recorder = MeetingRecorder()
    private var cancellables = Set<AnyCancellable>()
    private var ticker: Timer?
    /// Once dismissed for the current mic session, don't keep re-prompting.
    private var dismissedThisSession = false

    init(detector: MeetingDetector, store: ShelfStore) {
        self.detector = detector
        self.store = store

        detector.$micActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.micActiveChanged(active) }
            }
            .store(in: &cancellables)

        recorder.levelHandler = { [weak self] level in
            DispatchQueue.main.async { self?.pushLevel(level) }
        }
    }

    /// Each tick gives the 4 bars *independent* random heights driven by the
    /// current level, so they jiggle naturally (not a left-to-right ripple).
    /// Throttled so the smooth bar animation has time to breathe.
    private func pushLevel(_ level: Float) {
        guard state == .recording else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelPush) > 0.16 else { return }
        lastLevelPush = now
        let base = min(1, max(0, level * 16))
        levels = (0..<4).map { _ in min(1, base * Float.random(in: 0.4...1.0)) }
    }

    var elapsedString: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func micActiveChanged(_ active: Bool) {
        if active {
            if state == .idle, !dismissedThisSession {
                state = .prompt
            }
        } else {
            dismissedThisSession = false
            if state == .prompt { state = .idle }
            // If a recording was running and the mic turned off, the call likely
            // ended — finish up automatically.
            if state == .recording { stopRecording() }
        }
    }

    func startRecording() {
        Task { @MainActor in
            do {
                try await recorder.start()
                elapsed = 0
                state = .recording
                startTicker()
            } catch {
                state = .error((error as? DriveError)?.text ?? error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        stopTicker()
        levels = [0, 0, 0, 0]
        state = .processing
        Task { @MainActor in
            await recorder.stop()
            await process()
        }
    }

    func dismissPrompt() {
        dismissedThisSession = true
        if state == .prompt { state = .idle }
    }

    func dismissError() { state = .idle }

    private func process() async {
        do {
            guard let micURL = recorder.micURL, let systemURL = recorder.systemURL else {
                throw DriveError.message("Recording files missing.")
            }
            async let mic = DeepgramService.transcribe(fileURL: micURL)
            async let system = DeepgramService.transcribe(fileURL: systemURL)
            let (micUtterances, systemUtterances) = try await (mic, system)

            let transcript = Self.merge(you: micUtterances, others: systemUtterances)
            guard !transcript.isEmpty else {
                throw DriveError.message("No speech was transcribed.")
            }

            let prompt = """
                Summarize this meeting transcript concisely. A 1–2 sentence \
                overview, then short bullets for key points, decisions, and \
                action items (with owners if mentioned). Lines are labeled \
                “You” (me) and “Others”. Keep it tight.

                Transcript:
                \(transcript)
                """
            // Low reasoning effort + a token cap make gpt-5-family models answer
            // far faster; fall back to a plain call if the model rejects them.
            let summary: String
            do {
                summary = try await OpenAIService.complete(prompt, reasoningEffort: "low", maxTokens: 900)
            } catch {
                summary = try await OpenAIService.complete(prompt)
            }

            let id = store.addNote(folderId: nil)
            store.setNoteContent(
                id,
                "# Meeting summary\n\n\(summary)\n\n---\n\n## Transcript\n\n\(transcript)"
            )
            state = .idle
        } catch {
            state = .error((error as? DriveError)?.text ?? error.localizedDescription)
        }
    }

    /// Interleaves the two streams by timestamp into a labeled transcript.
    private static func merge(you: [Utterance], others: [Utterance]) -> String {
        let labeled = you.map { ($0.start, "You", $0.text) }
            + others.map { ($0.start, "Others", $0.text) }
        return labeled
            .sorted { $0.0 < $1.0 }
            .map { "**\($0.1):** \($0.2)" }
            .joined(separator: "\n")
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed += 1 }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
