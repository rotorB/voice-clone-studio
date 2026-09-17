import AVFoundation
import Foundation

/// All graph and queue mutations run on the main actor, including completion callbacks.
@MainActor
final class PCMStreamPlayer {
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let tempo = AVAudioUnitTimePitch()
    private var format: AVAudioFormat?
    private var generation = UUID()
    private(set) var queuedSeconds = 0.0
    private(set) var playbackRate = 1.0
    private var baseRate = 1.0
    private var automatic = false
    private var phraseBuffers: [Int: Int] = [:]
    var queuedPhraseIDs: [Int] { phraseBuffers.keys.sorted() }
    var remainingSeconds: Double { queuedSeconds / playbackRate }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(node)
        engine.attach(tempo)
    }

    func configure(sampleRate: Double) throws {
        // Metadata marks a phrase, not a new playback session. Preserve every queued buffer.
        if let format {
            guard format.sampleRate == sampleRate else {
                throw BackendError.api("Audio sample rate changed during Live Voice. Restart the stream.")
            }
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw BackendError.api("Invalid streaming audio format.")
        }
        engine.connect(node, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        try engine.start()
        self.format = format
        node.play()
    }

    func setTempo(rate: Double, automatic: Bool) {
        baseRate = min(1.5, max(0.8, rate))
        self.automatic = automatic
        if !automatic {
            playbackRate = baseRate
            tempo.rate = Float(playbackRate)
        }
    }

    /// Called every 200 ms. Catch up gently; never discard speech to reduce lag.
    func updateTempo() {
        let extra = automatic ? min(0.35, max(0, queuedSeconds - 2) * 0.05) : 0
        let target = min(1.5, baseRate + extra)
        playbackRate += min(0.02, max(-0.02, target - playbackRate))
        tempo.rate = Float(playbackRate)
    }

    func schedule(_ data: Data, phraseID: Int = 0) {
        guard let format else { return }
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0, data.count % 2 == 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let target = buffer.floatChannelData?[0] else { return }
            for index in 0..<frames {
                let sample = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                target[index] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        let seconds = Double(frames) / format.sampleRate
        let scheduledGeneration = generation
        queuedSeconds += seconds
        phraseBuffers[phraseID, default: 0] += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == scheduledGeneration else { return }
                self.queuedSeconds = max(0, self.queuedSeconds - seconds)
                let remaining = (self.phraseBuffers[phraseID] ?? 1) - 1
                self.phraseBuffers[phraseID] = remaining > 0 ? remaining : nil
            }
        }
    }

    func stop() {
        generation = UUID() // Ignore delayed callbacks from the previous session.
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(tempo)
        format = nil
        queuedSeconds = 0
        phraseBuffers = [:]
        playbackRate = baseRate
        tempo.rate = Float(playbackRate)
    }
}
