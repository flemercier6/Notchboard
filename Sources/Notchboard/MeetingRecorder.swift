import AVFoundation
import ScreenCaptureKit

/// Records two separate audio streams during a meeting:
///   • the user's microphone (their own voice) via AVAudioEngine, and
///   • all system audio (the other participants) via ScreenCaptureKit.
/// Each is written to its own WAV file so they can be transcribed separately.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.notchboard.meeting.audio")

    private(set) var micURL: URL?
    private(set) var systemURL: URL?
    private(set) var startedAt: Date?

    /// Called (on audio threads) with the RMS level (0…1-ish) of each buffer —
    /// mic or system — so the UI can drive a live visualizer.
    var levelHandler: ((Float) -> Void)?

    func start() async throws {
        let dir = Self.recordingsDir()
        let stamp = Int(Date().timeIntervalSince1970)
        let micURL = dir.appendingPathComponent("mic-\(stamp).wav")
        let systemURL = dir.appendingPathComponent("system-\(stamp).wav")
        self.micURL = micURL
        self.systemURL = systemURL
        startedAt = Date()

        try startMic(to: micURL)
        try await startSystem()
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        micFile = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        audioQueue.sync { systemFile = nil }   // flush
    }

    // MARK: - Microphone

    private func startMic(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        micFile = try AVAudioFile(forWriting: url, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.micFile?.write(from: buffer)
            if let handler = self?.levelHandler { handler(Self.rms(buffer)) }
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystem() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw DriveError.message("No display available for system-audio capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // A tiny video stream — SCStream needs a screen output, but we discard it.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.toPCMBuffer() else { return }
        do {
            if systemFile == nil, let url = systemURL {
                systemFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
            }
            try systemFile?.write(from: pcm)
            levelHandler?(Self.rms(pcm))
        } catch {
            // Drop a bad buffer rather than tear down the capture.
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Capture ended (e.g. permission revoked). Nothing to do here for now.
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        let data = channels[0]
        var i = 0
        while i < frames { sum += data[i] * data[i]; i += 1 }
        return (sum / Float(frames)).squareRoot()
    }

    static func recordingsDir() -> URL {
        let dir = ShelfPersistence.directory.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension CMSampleBuffer {
    /// Converts a Linear-PCM CMSampleBuffer (e.g. from ScreenCaptureKit) into an
    /// AVAudioPCMBuffer that can be written to an AVAudioFile.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        )
        return status == noErr ? pcm : nil
    }
}
