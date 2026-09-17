import AppKit
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct TextTrack: Identifiable {
    var id: String { audio.filename }
    let text: String
    let audio: GeneratedResponse
}

/// How a typed line should be delivered. Emotion, pace and pitch are post-processing on the
/// finished take; variation is the sampling temperature, so it changes the take itself.
struct Delivery: Codable, Equatable {
    var emotion = "As in the reference"
    var strength = 0.0
    var pace = 1.0
    var pitch = 0.0
    var variation = 0.7

    static let emotions = ["As in the reference", "Joy", "Sadness", "Anger", "Fear", "Calm"]
    static let neutral = Delivery()

    var isNeutral: Bool {
        (emotion == "As in the reference" || strength == 0)
            && abs(pace - 1) < 0.005 && abs(pitch) < 0.01 && abs(variation - 0.7) < 0.005
    }

    var payload: [String: Any] {
        ["emotion": emotion, "emotion_strength": strength,
         "pace": pace, "pitch": pitch, "temperature": variation]
    }

    var summary: String {
        if isNeutral { return "As in the reference" }
        var parts: [String] = []
        if emotion != "As in the reference" && strength > 0 {
            parts.append("\(emotion.lowercased()) \(Int(strength * 100)) %")
        }
        if abs(pace - 1) >= 0.005 { parts.append(String(format: "pace %.2f×", pace)) }
        if abs(pitch) >= 0.01 { parts.append(String(format: "pitch %+.1f st", pitch)) }
        if abs(variation - 0.7) >= 0.005 { parts.append(String(format: "variation %.2f", variation)) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class StudioModel: ObservableObject {
    let backend = BackendService()
    private let sampleCapture = CaptureController()
    private var signalWorker = SignalAnalysisWorker()
    private var sampleSession = UUID()
    @Published var voiceRegions: [VoiceRegion] = []
    @Published var onlineVoiceHints = true
    @Published var analysisMS = 0.0
    private let samplePlayer = SamplePlayer()
    private let trackPlayer = TrackPlayer()
    private let live = LiveStreamController()
    private var samplePlaybackTask: Task<Void, Never>?
    private var trackTicker: Task<Void, Never>?
    private var sampleCaptureWatchdog: Task<Void, Never>?
    private var bootTask: Task<Void, Never>?
    private var backendMonitorTask: Task<Void, Never>?

    @Published var selectedSection = 0
    @Published var captureSource: CaptureSource = .microphone
    @Published var isRecording = false
    @Published var sampleInputLevel = 0.0
    @Published var sampleLevels: [Double] = []
    @Published var isAuditioning = false
    @Published var samples: [Float] = []
    @Published var sampleRate = 44_100.0
    @Published var selectionStart = 0.0
    @Published var selectionEnd = 0.0
    @Published var playhead = 0.0
    @Published var spectrum: [[Double]] = []
    @Published var sampleStatus = "Record or load 6–15 seconds of clean speech."
    @Published var transcript = ""
    @Published var referenceReady = false
    @Published var isWorking = false
    @Published var speakerMode = "conservative"
    @Published var voices: [VoiceCandidate] = []
    @Published var mixed: [Segment] = []
    @Published var recordingBufferSeconds = 10.0
    @Published var savedVoices: [SavedVoice] = []
    @Published var voiceName = ""
    @Published var activeVoiceID: String?

    @Published var typedText = ""
    @Published var tracks: [TextTrack] = []
    @Published var textTemplates: [String] = []
    @Published var delivery = Delivery()
    /// Where generated takes play. `nil` means the system default; anything else is routed
    /// to that device alone, so the rest of the Mac keeps its own output.
    @Published var playbackDevice: AudioDeviceID?
    @Published var trackElapsed = 0.0
    @Published var trackDuration = 0.0
    @Published var isTrackPaused = false
    @Published var generationStatus = "Prepare a voice reference first."
    @Published var playingTrack: String?

    @Published var liveSource: CaptureSource = .microphone
    @Published var pauseSeconds = 0.42
    @Published var endpointMode = "sentence"
    @Published var liveTempo = 1.0 {
        didSet { live.setTempo(rate: liveTempo, automatic: automaticTempo) }
    }
    @Published var automaticTempo = false {
        didSet { live.setTempo(rate: liveTempo, automatic: automaticTempo) }
    }
    @Published var actualTempo = 1.0
    @Published var telemetry = LiveTelemetry()
    @Published var livePhrases: [LivePhrase] = []
    @Published var queuedPhraseIDs: [Int] = []
    @Published var liveLevels: [Double] = []
    @Published var audioQueueSeconds = 0.0
    @Published var isLive = false
    @Published var liveState = "IDLE"
    @Published var liveStatus = "Prepare a voice reference first."
    @Published var liveTranscript = "—"
    @Published var liveInputLevel = 0.0
    @Published var asrMetric = "—"
    @Published var firstAudioMetric = "—"
    @Published var playbackMetric = "0.0 s"
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var selectedOutput: AudioDeviceID = 0
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedInput = ""
    @Published var recognitionLanguage = "Auto"
    @Published var detectedLanguage = "—"
    @Published var translatorEnabled = false
    @Published var translationSource = "Russian"
    @Published var translationTarget = "English"
    @Published var isRestartingBackend = false

    var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    init() {
        live.onState = { [weak self] state, message in
            self?.liveState = state
            self?.liveStatus = message
            if state == "ERROR" { self?.isLive = false }
        }
        live.onTranscript = { [weak self] text in self?.liveTranscript = text }
        live.onLanguage = { [weak self] language in self?.detectedLanguage = language }
        live.onInputLevel = { [weak self] level in
            guard let self else { return }
            self.liveInputLevel = level
            self.liveLevels.append(level)
            if self.liveLevels.count > 100 { self.liveLevels.removeFirst(self.liveLevels.count - 100) }
        }
        live.onTelemetry = { [weak self] value in self?.telemetry = value }
        live.onPhraseEvent = { [weak self] value in self?.updatePhrase(value) }
        live.onQueue = { [weak self] ids in
            guard let self else { return }
            self.queuedPhraseIDs = ids
            for index in self.livePhrases.indices {
                let id = self.livePhrases[index].id
                if ids.first == id { self.livePhrases[index].state = "Playing" }
                else if ids.contains(id) { self.livePhrases[index].state = "Queued" }
                else if self.livePhrases[index].generationDone { self.livePhrases[index].state = "Played" }
            }
        }
        live.onPlayback = { [weak self] seconds, rate in
            self?.playbackMetric = String(format: "≈ %.1f s", seconds)
            self?.audioQueueSeconds = seconds
            self?.actualTempo = rate
        }
        live.onMetrics = { [weak self] asr, first, _ in
            if asr != "—" { self?.asrMetric = asr }
            if first != "—" { self?.firstAudioMetric = first }
        }
        loadTextTemplates()
        loadDelivery()
    }

    // MARK: - Text templates

    private static let templatesKey = "voiceStudio.textTemplates"

    func loadTextTemplates() {
        if let stored = UserDefaults.standard.array(forKey: Self.templatesKey) as? [String] {
            textTemplates = stored
            return
        }
        textTemplates = [
            "Hi, this is a quick test of my voice.",
            "Thanks for the message — I'll get back to you shortly.",
            "Recording starts in three, two, one.",
        ]
        persistTextTemplates()
    }

    func saveTextTemplate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !textTemplates.contains(trimmed) else { return }
        textTemplates.insert(trimmed, at: 0)
        if textTemplates.count > 20 { textTemplates.removeLast(textTemplates.count - 20) }
        persistTextTemplates()
    }

    func removeTextTemplate(_ text: String) {
        textTemplates.removeAll { $0 == text }
        persistTextTemplates()
    }

    private func persistTextTemplates() {
        UserDefaults.standard.set(textTemplates, forKey: Self.templatesKey)
    }

    // MARK: - Delivery

    private static let deliveryKey = "voiceStudio.delivery"
    private static let playbackDeviceKey = "voiceStudio.playbackDevice"

    private func loadDelivery() {
        if let data = UserDefaults.standard.data(forKey: Self.deliveryKey),
           let stored = try? JSONDecoder().decode(Delivery.self, from: data) {
            delivery = stored
        }
        let stored = UserDefaults.standard.integer(forKey: Self.playbackDeviceKey)
        playbackDevice = stored > 0 ? AudioDeviceID(stored) : nil
    }

    func persistDelivery() {
        guard let data = try? JSONEncoder().encode(delivery) else { return }
        UserDefaults.standard.set(data, forKey: Self.deliveryKey)
    }

    func resetDelivery() {
        delivery = .neutral
        persistDelivery()
    }

    /// Routing is per take, not system-wide: the system default output is left alone.
    func selectPlaybackDevice(_ id: AudioDeviceID?) {
        playbackDevice = id
        UserDefaults.standard.set(Int(id ?? 0), forKey: Self.playbackDeviceKey)
        let name = id.flatMap { device in outputDevices.first(where: { $0.id == device })?.name }
        generationStatus = "Takes play through \(name ?? "the system output")."
        if playingTrack != nil { stopTrack() }
    }

    var playbackDeviceName: String {
        guard let playbackDevice else { return "System output" }
        return outputDevices.first(where: { $0.id == playbackDevice })?.name ?? "Selected device"
    }

    /// One tap from "I just recorded something" to "I have a voice".
    func useWholeRecording() async {
        selectionStart = 0
        selectionEnd = duration
        await prepareSelection()
    }

    func beginBoot() {
        guard bootTask == nil else { return }
        bootTask = Task { [weak self] in await self?.boot() }
    }

    private func updatePhrase(_ event: [String: Any]) {
        guard let id = event["phrase_id"] as? Int, let type = event["type"] as? String else { return }
        if !livePhrases.contains(where: { $0.id == id }) { livePhrases.append(LivePhrase(id: id)) }
        guard let index = livePhrases.firstIndex(where: { $0.id == id }) else { return }
        if let text = event["text"] as? String { livePhrases[index].text = text; livePhrases[index].state = "Synthesizing" }
        if let seconds = event["input_seconds"] as? Double { livePhrases[index].inputSeconds = seconds }
        if type == "done" {
            livePhrases[index].generationDone = true
            livePhrases[index].outputSeconds = event["output_seconds"] as? Double ?? 0
        }
        // Keep every pending phrase, plus a small completed history.
        let completed = livePhrases.filter { $0.state == "Played" }.map(\.id)
        let expired = Set(completed.dropLast(12))
        livePhrases.removeAll { expired.contains($0.id) }
    }

    func boot() async {
        refreshInputs()
        refreshOutputs()
        do {
            try await backend.ensureRunning()
            let health = try await backend.health()
            referenceReady = health.ready
            if health.ready {
                detectedLanguage = health.referenceLanguage ?? "—"
                generationStatus = "Voice reference ready."
                liveStatus = "Reference ready — Live Voice can start."
            }
            await refreshVoiceLibrary()
            startBackendMonitor()
        } catch is CancellationError {
            return
        } catch {
            sampleStatus = error.localizedDescription
        }
    }

    func refreshOutputs() {
        let result = AudioDeviceManager.outputs()
        outputDevices = result.0
        selectedOutput = result.1 ?? outputDevices.first?.id ?? 0
    }

    func refreshInputs() {
        let result = AudioDeviceManager.inputs()
        inputDevices = result.0
        if !inputDevices.contains(where: { $0.id == selectedInput }) {
            selectedInput = result.1 ?? inputDevices.first?.id ?? ""
        }
    }

    func selectInput(_ id: String) {
        selectedInput = id
        captureSource = .microphone
        liveSource = .microphone
        let name = inputDevices.first(where: { $0.id == id })?.name ?? "microphone"
        sampleStatus = "Microphone selected: \(name)"
        liveStatus = "Microphone selected: \(name)"
    }

    func selectOutput(_ id: AudioDeviceID) {
        do {
            try AudioDeviceManager.select(id)
            selectedOutput = id
            liveStatus = "Output: \(outputDevices.first(where: { $0.id == id })?.name ?? "device")"
        } catch { liveStatus = error.localizedDescription }
    }

    func startRecording() async {
        guard !isRecording else { return }
        stopLive()
        sampleSession = UUID()
        signalWorker = SignalAnalysisWorker()
        voiceRegions = []
        samples = []
        sampleInputLevel = 0
        spectrum = []
        voices = []
        mixed = []
        referenceReady = false
        transcript = ""
        isRecording = true
        sampleStatus = "Requesting access to \(captureSource.rawValue.lowercased())…"
        do {
            refreshInputs()
            let inputID = captureSource == .microphone && !selectedInput.isEmpty ? selectedInput : nil
            let session = sampleSession
            sampleRate = try await sampleCapture.start(source: captureSource, inputDeviceID: inputID) { [weak self] chunk, rate in
                DispatchQueue.main.async {
                    guard let self, self.sampleSession == session, self.isRecording else { return }
                    self.appendSamples(chunk, rate: rate)
                }
            }
            let sourceName = captureSource == .microphone
                ? inputDevices.first(where: { $0.id == selectedInput })?.name ?? "microphone"
                : "system audio"
            sampleStatus = "Recording \(sourceName) · \(Int(sampleRate)) Hz · latest \(Int(recordingBufferSeconds)) seconds"
            sampleCaptureWatchdog?.cancel()
            sampleCaptureWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.isRecording, self.samples.isEmpty else { return }
                self.sampleStatus = "Capture opened, but macOS delivered no PCM frames. Stop and reselect the input device."
            }
        } catch {
            isRecording = false
            sampleStatus = error.localizedDescription
        }
    }

    func stopRecording() {
        sampleCaptureWatchdog?.cancel()
        sampleCaptureWatchdog = nil
        sampleCapture.stop()
        isRecording = false
        sampleInputLevel = 0
        finishSample(preserveRegions: true)
    }

    func loadFile(_ url: URL) {
        stopRecording()
        do {
            let loaded = try AudioFileLoader.load(url, maximumSeconds: recordingBufferSeconds)
            samples = loaded.0
            sampleRate = loaded.1
            finishSample()
            sampleStatus = "\(url.lastPathComponent) · latest \(String(format: "%.1f", duration)) s ready"
        } catch {
            sampleStatus = error.localizedDescription
        }
    }

    func playSelection() {
        if isAuditioning { stopAudition(); return }
        samplePlaybackTask?.cancel()
        let from = selectionStart
        let to = selectionEnd
        do {
            try samplePlayer.play(samples: samples, sampleRate: sampleRate, from: selectionStart, to: selectionEnd) { [weak self] in
                self?.samplePlaybackTask?.cancel()
                self?.isAuditioning = false
                self?.playhead = self?.selectionEnd ?? 0
            }
            isAuditioning = true
            playhead = selectionStart
            samplePlaybackTask = Task { [weak self] in
                let started = Date()
                while !Task.isCancelled {
                    let position = from + Date().timeIntervalSince(started)
                    if position >= to { break }
                    self?.playhead = position
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            isAuditioning = false
            sampleStatus = error.localizedDescription
        }
    }

    func stopAudition() {
        samplePlaybackTask?.cancel()
        samplePlayer.stop()
        isAuditioning = false
        playhead = selectionStart
    }

    func prepareSelection() async {
        guard selectionEnd - selectionStart >= 1 else { return }
        activeVoiceID = nil
        isWorking = true
        sampleStatus = "Qwen3-ASR is transcribing the sample and preparing the clone…"
        do {
            let prepared = try await backend.prepare(
                samples: samples, sampleRate: sampleRate,
                from: selectionStart, to: selectionEnd, language: recognitionLanguage
            )
            applyPrepared(prepared)
        } catch { sampleStatus = error.localizedDescription }
        isWorking = false
    }

    func analyzeVoices() async {
        guard selectionEnd - selectionStart >= 1 else { return }
        isWorking = true
        sampleStatus = "Analyzing speaker footprints…"
        do {
            let result = try await backend.analyze(
                samples: samples, sampleRate: sampleRate,
                from: selectionStart, to: selectionEnd, mode: speakerMode
            )
            let offset = selectionStart
            voices = result.voices.map { voice in
                VoiceCandidate(
                    id: voice.id, name: voice.name, url: voice.url,
                    seconds: voice.seconds, profile: voice.profile, confidence: voice.confidence,
                    segments: voice.segments.map { Segment(start: $0.start + offset, end: $0.end + offset) }
                )
            }
            mixed = result.mixed.map { Segment(start: $0.start + offset, end: $0.end + offset) }
            sampleStatus = "Found \(voices.count) voice(s). Click a lane or select a voice."
        } catch { sampleStatus = error.localizedDescription }
        isWorking = false
    }

    func selectVoice(_ voice: VoiceCandidate) async {
        activeVoiceID = nil
        isWorking = true
        sampleStatus = "Preparing \(voice.name)…"
        do { applyPrepared(try await backend.selectVoice(voice.id, language: recognitionLanguage)) }
        catch { sampleStatus = error.localizedDescription }
        isWorking = false
    }

    func choose(segment: Segment) {
        selectionStart = min(duration, segment.start)
        selectionEnd = min(duration, segment.end)
        playSelection()
    }

    func saveTranscript() async {
        do {
            try await backend.updateTranscript(transcript)
            sampleStatus = "Transcript applied to the voice reference."
        } catch { sampleStatus = error.localizedDescription }
    }

    func refreshVoiceLibrary() async {
        do { savedVoices = try await backend.voiceLibrary() }
        catch { if backend.isOnline { sampleStatus = error.localizedDescription } }
    }

    func saveCurrentVoice() async {
        let name = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard referenceReady, !name.isEmpty else { return }
        isWorking = true
        do {
            let voice = try await backend.saveVoice(name: name)
            activeVoiceID = voice.id
            voiceName = ""
            await refreshVoiceLibrary()
            sampleStatus = "Saved \(voice.name) to Voice Library."
        } catch { sampleStatus = error.localizedDescription }
        isWorking = false
    }

    func activateSavedVoice(_ voice: SavedVoice) async {
        isWorking = true
        sampleStatus = "Loading \(voice.name)…"
        do {
            applyPrepared(try await backend.activateVoice(voice.id))
            if let path = voice.audio {
                let loaded = try AudioFileLoader.load(
                    URL(fileURLWithPath: path), maximumSeconds: max(voice.seconds, recordingBufferSeconds)
                )
                samples = loaded.0
                sampleRate = loaded.1
                finishSample()
            }
            activeVoiceID = voice.id
            sampleStatus = "\(voice.name) ready · TTS warmed up."
        } catch { sampleStatus = error.localizedDescription }
        isWorking = false
    }

    func deleteSavedVoice(_ voice: SavedVoice) async {
        isWorking = true
        do {
            try await backend.deleteVoice(voice.id)
            savedVoices.removeAll { $0.id == voice.id }
            if activeVoiceID == voice.id { activeVoiceID = nil }
            sampleStatus = "Deleted \(voice.name) from Voice Library."
        } catch {
            sampleStatus = error.localizedDescription
        }
        isWorking = false
    }

    func generateText() async {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard referenceReady, !text.isEmpty, !isWorking else { return }
        isWorking = true
        generationStatus = "Synthesizing audio locally…"
        do {
            let track = try await backend.synthesize(text, delivery: delivery)
            let item = TextTrack(text: text, audio: track)
            tracks.insert(item, at: 0)
            generationStatus = track.stats
            await play(item)
        } catch { generationStatus = error.localizedDescription }
        isWorking = false
    }

    func play(_ track: TextTrack, from seconds: Double = 0) async {
        if playingTrack == track.id && seconds == 0 { stopTrack(); return }
        do {
            let url = try await cachedAudio(for: track)
            playingTrack = track.id
            try trackPlayer.play(url: url, device: playbackDevice, from: seconds) { [weak self] in
                self?.finishTrack()
            }
            trackDuration = trackPlayer.duration
            isTrackPaused = false
            startTrackTicker()
        } catch {
            generationStatus = error.localizedDescription
            playingTrack = nil
        }
    }

    /// Pause and resume the take that is playing; the transport in the text stage drives it.
    func toggleTrackPause() {
        guard playingTrack != nil else { return }
        do {
            if trackPlayer.isPaused { try trackPlayer.resume() } else { trackPlayer.pause() }
            isTrackPaused = trackPlayer.isPaused
        } catch { generationStatus = error.localizedDescription }
    }

    func seekTrack(to seconds: Double) {
        guard let id = playingTrack, let track = tracks.first(where: { $0.id == id }) else { return }
        trackElapsed = seconds
        Task { await play(track, from: seconds) }
    }

    func stopTrack() {
        trackPlayer.stop()
        trackTicker?.cancel()
        trackTicker = nil
        playingTrack = nil
        isTrackPaused = false
        trackElapsed = 0
    }

    private func finishTrack() {
        stopTrack()
        generationStatus = "Playback finished."
    }

    /// The backend serves takes over HTTP; playing one through a chosen device needs a file
    /// on disk, so each take is fetched once and kept in the caches directory.
    private func cachedAudio(for track: TextTrack) async throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Voice clone Studio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: track.audio.filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = try await backend.audioData(from: track.audio.url)
            try data.write(to: url)
        }
        return url
    }

    private func startTrackTicker() {
        trackTicker?.cancel()
        trackTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.playingTrack != nil else { return }
                self.trackElapsed = self.trackPlayer.elapsed
            }
        }
    }

    func revealOutput() {
        NSWorkspace.shared.open(backend.outputDirectory)
    }

    func reveal(_ track: TextTrack) {
        NSWorkspace.shared.selectFile(
            backend.outputDirectory.appending(path: track.audio.filename).path,
            inFileViewerRootedAtPath: backend.outputDirectory.path
        )
    }

    func toggleLive() async {
        if isLive { stopLive(); return }
        guard referenceReady else {
            liveState = "NEEDS REFERENCE"
            liveStatus = "Prepare a sample in the first section."
            return
        }
        isLive = true
        livePhrases = []
        liveLevels = []
        telemetry = LiveTelemetry()
        asrMetric = "—"
        firstAudioMetric = "—"
        live.setTempo(rate: liveTempo, automatic: automaticTempo)
        do {
            refreshInputs()
            let inputID = liveSource == .microphone && !selectedInput.isEmpty ? selectedInput : nil
            try await live.start(
                source: liveSource, inputDeviceID: inputID,
                pause: pauseSeconds, language: recognitionLanguage,
                translate: translatorEnabled, sourceLanguage: translationSource,
                targetLanguage: translationTarget, endpointMode: endpointMode
            )
        } catch {
            isLive = false
            liveState = "ERROR"
            liveStatus = error.localizedDescription
        }
    }

    func stopLive() {
        guard isLive else { return }
        live.stop()
        isLive = false
        liveInputLevel = 0
        liveState = "IDLE"
        liveStatus = "Stream stopped"
    }

    func shutdown() {
        bootTask?.cancel()
        backendMonitorTask?.cancel()
        sampleCaptureWatchdog?.cancel()
        sampleCapture.stop()
        live.stop()
        trackPlayer.stop()
        trackTicker?.cancel()
        samplePlayer.stop()
        backend.stop()
    }

    private func appendSamples(_ chunk: [Float], rate: Double) {
        sampleRate = rate
        let rms = sqrt(chunk.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, chunk.count)))
        sampleInputLevel = max(0, min(1, (20 * log10(rms + 0.000_001) + 60) / 50))
        sampleLevels.append(sampleInputLevel)
        if sampleLevels.count > 100 { sampleLevels.removeFirst(sampleLevels.count - 100) }
        samples.append(contentsOf: chunk)
        let maximum = Int(rate * recordingBufferSeconds)
        if samples.count > maximum { samples.removeFirst(samples.count - maximum) }
        selectionStart = 0
        selectionEnd = duration
        let session = sampleSession
        signalWorker.append(chunk, rate: rate, capacity: recordingBufferSeconds, classify: onlineVoiceHints) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.sampleSession == session, self.isRecording else { return }
                self.spectrum = result.spectrum
                self.voiceRegions = result.regions
                self.analysisMS = result.elapsedMS
            }
        }
    }

    private func finishSample(preserveRegions: Bool = false) {
        sampleSession = UUID()
        let session = sampleSession
        if !preserveRegions { voiceRegions = [] }
        samplePlaybackTask?.cancel()
        samplePlayer.stop()
        selectionStart = 0
        selectionEnd = duration
        playhead = 0
        let snapshot = samples, rate = sampleRate
        Task { [weak self] in
            let result = await SignalAnalysisWorker.file(snapshot, rate: rate)
            guard let self, self.sampleSession == session else { return }
            self.spectrum = result.spectrum
            self.analysisMS = result.elapsedMS
        }
        voices = []
        mixed = []
        sampleStatus = samples.isEmpty ? "The recording is empty." : "Sample ready: listen, select a range, and prepare the reference."
    }

    private func applyPrepared(_ prepared: PreparedResponse) {
        transcript = prepared.text
        detectedLanguage = prepared.language ?? detectedLanguage
        referenceReady = true
        sampleStatus = "Reference ready · \(String(format: "%.1f", prepared.seconds)) s · \(String(format: "%.2f", prepared.elapsed)) s processing"
        generationStatus = "Voice reference ready — enter text."
        liveStatus = "Reference ready — Live Voice can start."
    }

    func restartBackend() async {
        guard !isRestartingBackend else { return }
        isRestartingBackend = true
        stopLive()
        sampleStatus = "Restarting ASR and voice engine…"
        generationStatus = "Restarting voice engine…"
        do {
            try await backend.restart()
            let health = try await backend.health()
            referenceReady = health.ready
            detectedLanguage = health.referenceLanguage ?? detectedLanguage
            sampleStatus = health.ready ? "Backend restarted · saved reference restored." : "Backend restarted · prepare a voice reference."
            generationStatus = health.ready ? "Voice reference ready — enter text." : "Prepare a voice reference first."
            liveStatus = health.ready ? "Reference ready — Live Voice can start." : "Prepare a voice reference first."
        } catch {
            referenceReady = false
            sampleStatus = error.localizedDescription
            generationStatus = error.localizedDescription
            liveStatus = error.localizedDescription
        }
        isRestartingBackend = false
    }

    func revealBackendLog() {
        backend.revealLog()
    }

    private func startBackendMonitor() {
        guard backendMonitorTask == nil else { return }
        backendMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backend.refreshHealth()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
