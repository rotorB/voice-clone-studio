import AVFoundation
import CoreAudio
import AudioToolbox
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

private let captureLog = Logger(subsystem: "studio.voiceclone.macos", category: "capture")

enum CaptureSource: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case system = "System Audio"
    var id: String { rawValue }
}

final class CaptureController {
    private var microphoneCapture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?

    func start(
        source: CaptureSource,
        inputDeviceID: String? = nil,
        handler: @escaping ([Float], Double) -> Void
    ) async throws -> Double {
        stop()
        switch source {
        case .microphone:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw BackendError.api("Microphone access is disabled. Enable Voice clone Studio in System Settings → Privacy & Security → Microphone.")
            }
            let capture = MicrophoneCapture(handler: handler)
            let sampleRate = try await capture.start(deviceID: inputDeviceID)
            microphoneCapture = capture
            return sampleRate
        case .system:
            let capture = SystemAudioCapture(handler: handler)
            try await capture.start()
            systemCapture = capture
            return 48_000
        }
    }

    func stop() {
        microphoneCapture?.stop()
        microphoneCapture = nil
        if let capture = systemCapture {
            Task { await capture.stop() }
        }
        systemCapture = nil
    }
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: ([Float], Double) -> Void
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "studio.microphone-capture", qos: .userInteractive)
    private var loggedFirstBuffer = false

    init(handler: @escaping ([Float], Double) -> Void) {
        self.handler = handler
    }

    func start(deviceID: String?) async throws -> Double {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        )
        let device = deviceID.flatMap { selected in
            discovery.devices.first(where: { $0.uniqueID == selected })
        } ?? AVCaptureDevice.default(for: .audio)
        guard let device, device.isConnected else {
            throw BackendError.api("The selected microphone is disconnected or unavailable.")
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw BackendError.api("macOS could not create an audio capture route for \(device.localizedName).")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        await withCheckedContinuation { continuation in
            queue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }
        guard session.isRunning else {
            captureLog.error("Capture session failed to start for \(device.localizedName, privacy: .public)")
            throw BackendError.api("The microphone capture session did not start.")
        }
        let sampleRate = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee.mSampleRate ?? 48_000
        captureLog.info("Started \(device.localizedName, privacy: .public) id=\(device.uniqueID, privacy: .public) rate=\(sampleRate, privacy: .public)")
        return sampleRate
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }

        var list = AudioBufferList()
        var retained: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retained
        )
        guard result == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(&list)
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(1, Int(basic.mChannelsPerFrame))
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            captureLog.info("First PCM buffer rate=\(basic.mSampleRate, privacy: .public) channels=\(channels, privacy: .public) bytes=\(buffer.mDataByteSize, privacy: .public)")
        }
        let isFloat = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let values: [Float]
        if isFloat && basic.mBitsPerChannel == 32 {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            values = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        } else if basic.mBitsPerChannel == 16 {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let source = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
            values = source.map { Float($0) / Float(Int16.max) }
        } else {
            return
        }
        if channels == 1 {
            handler(values, basic.mSampleRate)
        } else {
            let frames = values.count / channels
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    mono[frame] += values[frame * channels + channel] / Float(channels)
                }
            }
            handler(mono, basic.mSampleRate)
        }
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let handler: ([Float], Double) -> Void
    private let queue = DispatchQueue(label: "studio.system-audio", qos: .userInteractive)
    private var stream: SCStream?

    init(handler: @escaping ([Float], Double) -> Void) {
        self.handler = handler
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw BackendError.api("No display is available for system audio capture.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.queueDepth = 1
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }

        var list = AudioBufferList()
        var retained: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retained
        )
        guard result == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(&list)
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let isFloat = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let sampleCount: Int
        var samples: [Float]
        if isFloat && basic.mBitsPerChannel == 32 {
            sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: sampleCount))
        } else if basic.mBitsPerChannel == 16 {
            sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let source = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: sampleCount)
            samples = source.map { Float($0) / Float(Int16.max) }
        } else {
            return
        }
        handler(samples, basic.mSampleRate)
    }
}

enum AudioFileLoader {
    static func load(_ url: URL, maximumSeconds: Double = 10) throws -> ([Float], Double) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw BackendError.api("Could not decode the audio file.") }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw BackendError.api("Unsupported audio format.") }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            for index in 0..<frames { mono[index] += channels[channel][index] / Float(channelCount) }
        }
        let maximum = Int(format.sampleRate * max(1, maximumSeconds))
        return (mono.count > maximum ? Array(mono.suffix(maximum)) : mono, format.sampleRate)
    }
}

final class SamplePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() {
        engine.attach(node)
    }

    func play(samples: [Float], sampleRate: Double, from: Double, to: Double, completion: @escaping () -> Void) throws {
        stop()
        let start = max(0, min(samples.count, Int(from * sampleRate)))
        let end = max(start, min(samples.count, Int(to * sampleRate)))
        guard end > start,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)) else { return }
        buffer.frameLength = AVAudioFrameCount(end - start)
        if let destination = buffer.floatChannelData?[0] {
            for index in start..<end { destination[index - start] = samples[index] }
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in DispatchQueue.main.async(execute: completion) }
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
        engine.disconnectNodeOutput(node)
    }
}

/// Plays a finished take. Unlike `AVAudioPlayer` this can be pointed at one specific
/// output device — a virtual microphone, say — without touching the system default, so a
/// take can be routed into a call while the rest of the Mac keeps its own output.
@MainActor
final class TrackPlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var file: AVAudioFile?
    private var offset = 0.0
    private var completion: (() -> Void)?

    private(set) var isPlaying = false
    private(set) var isPaused = false
    private(set) var duration = 0.0

    /// Seconds into the take, measured from the render clock while it runs.
    var elapsed: Double {
        guard let node, let file else { return offset }
        guard isPlaying, !isPaused,
              let render = node.lastRenderTime, let played = node.playerTime(forNodeTime: render) else {
            return min(duration, offset)
        }
        let rate = file.processingFormat.sampleRate
        return min(duration, offset + Double(played.sampleTime) / rate)
    }

    func play(url: URL, device: AudioDeviceID?, from seconds: Double = 0,
              completion: @escaping () -> Void) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        duration = Double(file.length) / format.sampleRate
        let start = max(0, min(duration - 0.05, seconds))
        let frame = AVAudioFramePosition(start * format.sampleRate)
        let frames = AVAudioFrameCount(max(1, file.length - frame))

        let engine = AVAudioEngine()
        // The device has to be chosen before the graph is wired and started.
        if let device { try engine.outputNode.auAudioUnit.setDeviceID(device) }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()

        node.scheduleSegment(file, startingFrame: frame, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.finish()
            }
        }
        node.play()

        self.engine = engine
        self.node = node
        self.file = file
        self.offset = start
        self.completion = completion
        isPlaying = true
        isPaused = false
    }

    func pause() {
        guard isPlaying, !isPaused, let node, let engine else { return }
        offset = elapsed
        node.pause()
        engine.pause()
        isPaused = true
    }

    func resume() throws {
        guard isPlaying, isPaused, let node, let engine, let file else { return }
        // The engine was paused mid-buffer; restart the segment from where it stopped so
        // the render clock and the progress bar agree.
        let format = file.processingFormat
        let frame = AVAudioFramePosition(offset * format.sampleRate)
        let frames = AVAudioFrameCount(max(1, file.length - frame))
        node.stop()
        try engine.start()
        node.scheduleSegment(file, startingFrame: frame, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.finish()
            }
        }
        node.play()
        isPaused = false
    }

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        file = nil
        offset = 0
        completion = nil
        isPlaying = false
        isPaused = false
    }

    private func finish() {
        let done = completion
        stop()
        done?()
    }
}
