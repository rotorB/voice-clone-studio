import AVFoundation
import Foundation

@MainActor
final class LiveStreamController {
    var onState: ((String, String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onLanguage: ((String) -> Void)?
    var onInputLevel: ((Double) -> Void)?
    var onMetrics: ((String, String, String) -> Void)?
    var onTelemetry: ((LiveTelemetry) -> Void)?
    var onPhraseEvent: (([String: Any]) -> Void)?
    var onQueue: (([Int]) -> Void)?
    private var currentPhraseID = 0

    private var capture = CaptureController()
    private let player = PCMStreamPlayer()
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var busy = false
    private var session = UUID()
    private var playbackTimer: Timer?
    var onPlayback: ((Double, Double) -> Void)?

    func setTempo(rate: Double, automatic: Bool) {
        player.setTempo(rate: rate, automatic: automatic)
        onPlayback?(player.remainingSeconds, player.playbackRate)
        onQueue?(player.queuedPhraseIDs)
    }

    private func refreshPlayback() {
        player.updateTempo()
        onPlayback?(player.remainingSeconds, player.playbackRate)
        onQueue?(player.queuedPhraseIDs)
        if player.queuedSeconds > 0 {
            onState?("PLAYING", busy ? "Playing queue · generating next audio" : "Playing queue · listening in parallel")
        } else if !busy {
            onState?("LISTENING", "Listening · speak the next phrase")
        }
    }
    private var lastLevelUpdate = Date.distantPast

    func start(
        source: CaptureSource, inputDeviceID: String?, pause: Double, language: String,
        translate: Bool, sourceLanguage: String, targetLanguage: String,
        endpointMode: String
    ) async throws {
        stop()
        guard let url = URL(string: "ws://127.0.0.1:7862/ws") else { return }
        let currentSession = session
        let sessionCapture = CaptureController()
        capture = sessionCapture
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        onState?("CONNECTING", "Connecting to the local streaming backend…")

        do {
            let sampleRate = try await sessionCapture.start(source: source, inputDeviceID: inputDeviceID) { [weak self] samples, rate in
                DispatchQueue.main.async {
                    guard let self, self.session == currentSession else { return }
                    self.send(samples: samples, sampleRate: rate)
                }
            }
            guard session == currentSession else { sessionCapture.stop(); return }
            let config = try JSONSerialization.data(withJSONObject: [
                "sample_rate": Int(sampleRate), "pause_seconds": pause, "language": language,
                "translate": translate, "source_language": sourceLanguage,
                "target_language": targetLanguage, "endpoint_mode": endpointMode,
            ])
            try await task.send(.string(String(decoding: config, as: UTF8.self)))
            guard session == currentSession else { sessionCapture.stop(); return }
            running = true
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.session == currentSession, self.running else { return }
                    self.refreshPlayback()
                }
            }
            playbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            receive()
        } catch {
            sessionCapture.stop()
            guard session == currentSession else { return }
            task.cancel(with: .goingAway, reason: nil)
            socket = nil
            throw error
        }
    }

    func stop() {
        session = UUID()
        playbackTimer?.invalidate()
        playbackTimer = nil
        running = false
        busy = false
        capture.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        player.stop()
        currentPhraseID = 0
        onQueue?([])
        onTelemetry?(LiveTelemetry())
        onPlayback?(0, player.playbackRate)
        lastLevelUpdate = .distantPast
        onInputLevel?(0)
    }

    private func send(samples: [Float], sampleRate: Double) {
        guard running else { return }
        let now = Date()
        let meanSquare = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))
        let decibels = max(-60, 20 * log10(sqrt(meanSquare) + 0.000_001))
        if now.timeIntervalSince(lastLevelUpdate) >= 0.05 {
            onInputLevel?(max(0, min(1, (decibels + 60) / 50)))
            lastLevelUpdate = now
        }
        // Keep capture full-duplex: inference and playback must never gate input PCM.
        guard let socket else { return }
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples { pcm.append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        let data = pcm.withUnsafeBytes { Data($0) }
        let currentSession = session
        socket.send(.data(data)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.session == currentSession, let error else { return }
                self.stop()
                self.onState?("ERROR", error.localizedDescription)
            }
        }
    }

    private func receive() {
        let currentSession = session
        socket?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.running, self.session == currentSession else { return }
                switch result {
                case .failure(let error):
                    self.onState?("ERROR", error.localizedDescription)
                    self.stop()
                case .success(let message):
                    switch message {
                    case .string(let value): self.handleJSON(value)
                    case .data(let data):
                        self.player.schedule(data, phraseID: self.currentPhraseID)
                    @unknown default: break
                    }
                    if self.running { self.receive() }
                }
            }
        }
    }

    private func handleJSON(_ value: String) {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "telemetry":
            if let telemetry = try? JSONDecoder().decode(LiveTelemetry.self, from: data) { onTelemetry?(telemetry) }
        case "probe":
            busy = true
            onState?("PROCESSING", json["message"] as? String ?? "Checking sentence boundary…")
        case "status":
            busy = false
            if player.queuedSeconds > 0 { refreshPlayback() }
            else { onState?("LISTENING", json["message"] as? String ?? "Speak now") }
        case "busy":
            onPhraseEvent?(json)
            busy = true
            let seconds = json["input_seconds"] as? Double ?? 0
            onState?("PROCESSING", String(format: "Phrase %.1f s · transcribing…", seconds))
        case "text":
            onPhraseEvent?(json)
            let text = json["text"] as? String ?? ""
            let asr = json["asr_ms"] as? Int ?? 0
            onTranscript?(text)
            if let language = json["language"] as? String { onLanguage?(language) }
            onMetrics?("\(asr) ms", "—", String(format: "%.1f s", player.queuedSeconds))
        case "audio_meta":
            currentPhraseID = json["phrase_id"] as? Int ?? currentPhraseID + 1
            let rate = json["sample_rate"] as? Double ?? Double(json["sample_rate"] as? Int ?? 24_000)
            let first = json["first_audio_ms"] as? Int ?? 0
            do { try player.configure(sampleRate: rate) } catch {
                stop()
                onState?("ERROR", error.localizedDescription)
                return
            }
            onMetrics?("—", "\(first) ms", String(format: "%.1f s", player.queuedSeconds))
            onState?("PLAYING", "Playing the cloned voice")
        case "done":
            onPhraseEvent?(json)
            busy = false
            refreshPlayback()
            onMetrics?("—", "—", String(format: "%.1f s", player.queuedSeconds))
        case "warning":
            busy = false
            onState?("LISTENING", json["message"] as? String ?? "No speech recognized · still listening")
        case "error":
            busy = false
            onState?("ERROR", json["message"] as? String ?? "Streaming backend error")
            stop()
        default: break
        }
    }
}
