import AVFoundation
import XCTest
@testable import VoiceCloneStudio

final class PCMStreamPlayerTests: XCTestCase {
    @MainActor
    private func makePlayer() throws -> (PCMStreamPlayer, AVAudioEngine) {
        let engine = AVAudioEngine()
        let player = PCMStreamPlayer(engine: engine)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try player.configure(sampleRate: 24_000)
        return (player, engine)
    }

    private func tone(_ frequency: Double, seconds: Double = 1) -> Data {
        let samples = (0..<Int(24_000 * seconds)).map {
            Int16(sin(2 * .pi * frequency * Double($0) / 24_000) * 12_000)
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    @MainActor
    func testNextPhrasePreservesAudioAndOrder() async throws {
        let (player, engine) = try makePlayer()
        defer { player.stop() }
        player.schedule(tone(440))
        try player.configure(sampleRate: 24_000) // The second phrase used to erase the first.
        player.schedule(tone(880))
        XCTAssertEqual(player.queuedSeconds, 2, accuracy: 0.001)

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
        var rendered: [Float] = []
        for _ in 0..<60 {
            let status = try engine.renderOffline(1024, to: buffer)
            if status == .success {
                rendered += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
        }
        XCTAssertGreaterThan(rendered.count, 48_000)
        guard rendered.count > 48_000 else { return }
        // Count zero crossings away from phrase boundaries and time-pitch latency.
        func frequency(_ start: Int) -> Double {
            let samples = Array(rendered[start..<(start + 12_000)])
            let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            return Double(crossings) * 2
        }
        XCTAssertEqual(frequency(6000), 440, accuracy: 5)
        XCTAssertEqual(frequency(30_000), 880, accuracy: 5)
    }

    @MainActor
    func testFasterPlaybackPreservesPitchAndShortensAudio() async throws {
        let (player, engine) = try makePlayer()
        defer { player.stop() }
        player.setTempo(rate: 1.5, automatic: false)
        player.schedule(tone(440, seconds: 2))
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
        var rendered: [Float] = []
        for _ in 0..<60 {
            if try engine.renderOffline(1024, to: buffer) == .success {
                rendered += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            }
        }
        let first = try XCTUnwrap(rendered.firstIndex(where: { abs($0) > 0.03 }))
        let last = try XCTUnwrap(rendered.lastIndex(where: { abs($0) > 0.03 }))
        XCTAssertEqual(Double(last - first) / 24_000, 2 / 1.5, accuracy: 0.12)
        let samples = Array(rendered[6000..<18_000])
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings) * 2, 440, accuracy: 5)
    }

    @MainActor
    func testTempoBoundsAndGentleCatchUp() async throws {
        let (player, _) = try makePlayer()
        defer { player.stop() }
        player.setTempo(rate: 1.2, automatic: false)
        player.schedule(tone(440, seconds: 12))
        XCTAssertEqual(player.remainingSeconds, 10, accuracy: 0.001)
        player.setTempo(rate: 1.2, automatic: true)
        player.updateTempo()
        XCTAssertEqual(player.playbackRate, 1.22, accuracy: 0.001)
        for _ in 0..<100 { player.updateTempo() }
        XCTAssertEqual(player.playbackRate, 1.5, accuracy: 0.001)
        player.setTempo(rate: 0.8, automatic: false)
        XCTAssertEqual(player.playbackRate, 0.8, accuracy: 0.001)
        XCTAssertEqual(player.remainingSeconds, 15, accuracy: 0.001)
    }

    @MainActor
    func testStopCallbacksCannotConsumeNewSession() async throws {
        let (player, _) = try makePlayer()
        defer { player.stop() }
        player.schedule(tone(440, seconds: 2))
        player.stop()
        try player.configure(sampleRate: 24_000)
        player.schedule(tone(880))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.queuedSeconds, 1, accuracy: 0.001)
    }

    @MainActor
    func testFormatChangeDoesNotEraseQueuedSpeech() async throws {
        let (player, _) = try makePlayer()
        defer { player.stop() }
        player.schedule(tone(440))
        XCTAssertThrowsError(try player.configure(sampleRate: 48_000))
        XCTAssertEqual(player.queuedSeconds, 1, accuracy: 0.001)
    }
}
