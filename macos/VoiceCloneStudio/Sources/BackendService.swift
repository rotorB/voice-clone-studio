import AppKit
import Darwin
import Foundation

struct HealthResponse: Decodable {
    let service: String?
    let pid: Int?
    let parentPID: Int?
    let instanceID: String?
    let busy: Bool?
    let ready: Bool
    let asrLoaded: Bool
    let ttsLoaded: Bool
    let asrState: String?
    let ttsState: String?
    let activeOperation: String?
    let uptimeSeconds: Int?
    let requestsTotal: Int?
    let averageResponseMS: Int?
    let trafficKBPS: Double?
    let lastASRMS: Int?
    let averageASRMS: Int?
    let lastTTSMS: Int?
    let averageTTSMS: Int?
    let lastError: String?
    let referenceLanguage: String?

    enum CodingKeys: String, CodingKey {
        case service, pid, busy
        case parentPID = "parent_pid"
        case instanceID = "instance_id"
        case ready
        case asrLoaded = "asr_loaded"
        case ttsLoaded = "tts_loaded"
        case asrState = "asr_state"
        case ttsState = "tts_state"
        case activeOperation = "active_operation"
        case uptimeSeconds = "uptime_seconds"
        case requestsTotal = "requests_total"
        case averageResponseMS = "average_response_ms"
        case trafficKBPS = "traffic_kbps"
        case lastASRMS = "last_asr_ms"
        case averageASRMS = "average_asr_ms"
        case lastTTSMS = "last_tts_ms"
        case averageTTSMS = "average_tts_ms"
        case lastError = "last_error"
        case referenceLanguage = "reference_language"
    }
}

struct PreparedResponse: Decodable {
    let text: String
    let seconds: Double
    let elapsed: Double
    let language: String?
}

struct SavedVoice: Decodable, Identifiable {
    let id: String
    let name: String
    let audio: String?
    let text: String
    let language: String?
    let seconds: Double
}

private struct VoiceLibraryResponse: Decodable {
    let voices: [SavedVoice]
}

struct Segment: Codable, Identifiable, Hashable {
    var id: String { "\(start)-\(end)" }
    let start: Double
    let end: Double
}

struct VoiceCandidate: Decodable, Identifiable {
    let id: String
    let name: String
    let url: String
    let seconds: Double
    let profile: String
    let confidence: Int
    let segments: [Segment]
}

struct SpeakerAnalysis: Decodable {
    let voices: [VoiceCandidate]
    let mixed: [Segment]
    let duration: Double
}

struct GeneratedResponse: Decodable, Identifiable {
    var id: String { filename }
    let url: String
    let filename: String
    let duration: Double
    let elapsed: Double
    let stats: String
}

private struct APIError: Decodable {
    let detail: String
}

enum BackendError: LocalizedError {
    case unavailable(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .api(let message): message
        }
    }
}

@MainActor
final class BackendService: ObservableObject {
    @Published var status = "Starting local MLX backend…"
    @Published var isOnline = false
    @Published var healthSnapshot: HealthResponse?
    @Published var healthLatencyMS: Int?

    let baseURL = URL(string: "http://127.0.0.1:7862")!
    let outputDirectory: URL
    private let instanceID = UUID().uuidString
    private let lockFile: URL
    private let logFile: URL
    private var process: Process?
    private var logHandle: FileHandle?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Voice clone Studio", directoryHint: .isDirectory)
        outputDirectory = support.appending(path: "output", directoryHint: .isDirectory)
        lockFile = support.appending(path: "backend.lock")
        logFile = support.appending(path: "backend.log")
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func ensureRunning() async throws {
        if let current = try? await health() {
            if current.instanceID == instanceID {
                isOnline = true
                healthSnapshot = current
                status = current.busy == true ? "Backend is processing" : "Backend ready"
                return
            }
            if current.service == "voice-clone-studio" {
                throw BackendError.unavailable(
                    "The backend belongs to another app instance (PID \(current.parentPID ?? 0)). Close the extra Voice clone Studio process."
                )
            }
        }

        let runtime = try locateRuntime()
        let task = Process()
        task.executableURL = runtime.python
        task.arguments = [
            runtime.script.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--instance-id", instanceID,
            "--lock-file", lockFile.path,
        ]
        task.currentDirectoryURL = runtime.workingDirectory
        var additions = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "VOICE_CLONE_OUTPUT_DIR": outputDirectory.path
        ]
        if let pythonHome = runtime.pythonHome { additions["PYTHONHOME"] = pythonHome.path }
        if let pythonPath = runtime.pythonPath { additions["PYTHONPATH"] = pythonPath }
        task.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        } else if let size = try? logFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
            try? Data().write(to: logFile)
        }
        let handle = try FileHandle(forWritingTo: logFile)
        try handle.seekToEnd()
        logHandle = handle
        task.standardOutput = handle
        task.standardError = handle
        try task.run()
        process = task

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if let response = try? await health(), response.instanceID == instanceID {
                isOnline = true
                healthSnapshot = response
                status = "Backend ready"
                return
            }
            if !task.isRunning { break }
        }
        stop()
        throw BackendError.unavailable("Could not start the local MLX backend. Details: \(logFile.path)")
    }

    deinit {
        if process?.isRunning == true { process?.terminate() }
        try? logHandle?.close()
    }

    func stop() {
        guard let task = process else { return }
        if task.isRunning {
            task.terminate()
            let deadline = Date().addingTimeInterval(1.5)
            while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
        }
        clearProcessState(status: "Backend stopped")
    }

    func health() async throws -> HealthResponse {
        var request = URLRequest(url: baseURL.appending(path: "/health"))
        request.timeoutInterval = 1.5
        return try await send(request)
    }

    func refreshHealth() async {
        let started = Date()
        do {
            let current = try await health()
            healthLatencyMS = Int(Date().timeIntervalSince(started) * 1000)
            healthSnapshot = current
            isOnline = true
            status = current.busy == true
                ? "Backend · \((current.activeOperation ?? "processing").replacingOccurrences(of: "_", with: " "))"
                : "Backend ready"
        } catch {
            healthLatencyMS = nil
            healthSnapshot = nil
            isOnline = false
            status = "Backend unavailable"
        }
    }

    func restart() async throws {
        status = "Restarting backend…"
        if let task = process, task.isRunning {
            task.terminate()
            for _ in 0..<30 where task.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
        }
        clearProcessState(status: "Restarting backend…")
        try await Task.sleep(for: .milliseconds(250))
        try await ensureRunning()
        await refreshHealth()
    }

    func revealLog() {
        NSWorkspace.shared.selectFile(logFile.path, inFileViewerRootedAtPath: logFile.deletingLastPathComponent().path)
    }

    private func clearProcessState(status newStatus: String) {
        process = nil
        try? logHandle?.close()
        logHandle = nil
        isOnline = false
        healthSnapshot = nil
        status = newStatus
    }

    func prepare(samples: [Float], sampleRate: Double, from: Double, to: Double, language: String) async throws -> PreparedResponse {
        let slice = Self.pcmData(samples: samples, sampleRate: sampleRate, from: from, to: to)
        var request = URLRequest(url: baseURL.appending(path: "/sample/select-region"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(Int(sampleRate)), forHTTPHeaderField: "X-Sample-Rate")
        request.setValue(language, forHTTPHeaderField: "X-ASR-Language")
        request.httpBody = slice
        return try await send(request)
    }

    func analyze(samples: [Float], sampleRate: Double, from: Double, to: Double, mode: String) async throws -> SpeakerAnalysis {
        let slice = Self.pcmData(samples: samples, sampleRate: sampleRate, from: from, to: to)
        var request = URLRequest(url: baseURL.appending(path: "/sample/analyze"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(Int(sampleRate)), forHTTPHeaderField: "X-Sample-Rate")
        request.setValue(mode, forHTTPHeaderField: "X-Speaker-Mode")
        request.setValue("0.9", forHTTPHeaderField: "X-Min-Voice-Seconds")
        request.setValue("0.55", forHTTPHeaderField: "X-Merge-Gap")
        request.httpBody = slice
        return try await send(request)
    }

    func selectVoice(_ id: String, language: String) async throws -> PreparedResponse {
        var request = URLRequest(url: baseURL.appending(path: "/sample/select/\(id)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(language, forHTTPHeaderField: "X-ASR-Language")
        return try await send(request)
    }

    func updateTranscript(_ text: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/sample/transcript"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let _: EmptyResponse = try await send(request)
    }

    func voiceLibrary() async throws -> [SavedVoice] {
        let response: VoiceLibraryResponse = try await get("/library")
        return response.voices
    }

    func saveVoice(name: String) async throws -> SavedVoice {
        var request = URLRequest(url: baseURL.appending(path: "/library/save"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        return try await send(request)
    }

    func activateVoice(_ id: String) async throws -> PreparedResponse {
        var request = URLRequest(url: baseURL.appending(path: "/library/select/\(id)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        return try await send(request)
    }

    func deleteVoice(_ id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/library/\(id)"))
        request.httpMethod = "DELETE"
        let _: EmptyResponse = try await send(request)
    }

    func synthesize(_ text: String, delivery: Delivery = .neutral) async throws -> GeneratedResponse {
        var request = URLRequest(url: baseURL.appending(path: "/text/synthesize"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["text": text]
        payload.merge(delivery.payload) { current, _ in current }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await send(request)
    }

    func audioData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw BackendError.api("Invalid audio URL.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response: response, data: data)
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(URLRequest(url: baseURL.appending(path: path)))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data).detail) ?? "Local backend error."
            throw BackendError.api(message)
        }
    }

    private static func pcmData(samples: [Float], sampleRate: Double, from: Double, to: Double) -> Data {
        let lower = max(0, min(samples.count, Int(from * sampleRate)))
        let upper = max(lower, min(samples.count, Int(to * sampleRate)))
        var pcm = [Int16]()
        pcm.reserveCapacity(upper - lower)
        for sample in samples[lower..<upper] {
            pcm.append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return pcm.withUnsafeBytes { Data($0) }
    }

    private func locateRuntime() throws -> BackendRuntime {
        if let resources = Bundle.main.resourceURL,
           let frameworks = Bundle.main.privateFrameworksURL {
            let backend = resources.appending(path: "backend", directoryHint: .isDirectory)
            let pythonHome = frameworks.appending(path: "Python.framework/Versions/3.11", directoryHint: .isDirectory)
            let python = pythonHome.appending(path: "Resources/Python.app/Contents/MacOS/Python")
            let script = backend.appending(path: "native_backend.py")
            let packages = backend.appending(path: "site-packages", directoryHint: .isDirectory)
            if FileManager.default.isExecutableFile(atPath: python.path),
               FileManager.default.fileExists(atPath: script.path),
               FileManager.default.fileExists(atPath: packages.path) {
                return BackendRuntime(
                    python: python, script: script, workingDirectory: backend,
                    pythonHome: pythonHome,
                    pythonPath: "\(packages.path):\(backend.path)"
                )
            }
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = sourceRoot.appending(path: ".venv/bin/python")
        let script = sourceRoot.appending(path: "native_backend.py")
        if FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: script.path) {
            return BackendRuntime(
                python: python, script: script, workingDirectory: sourceRoot,
                pythonHome: nil, pythonPath: nil
            )
        }
        throw BackendError.unavailable("The embedded MLX backend is damaged. Reinstall Voice clone Studio.")
    }
}

private struct BackendRuntime {
    let python: URL
    let script: URL
    let workingDirectory: URL
    let pythonHome: URL?
    let pythonPath: String?
}

private struct EmptyResponse: Decodable {
    let ok: Bool
}
