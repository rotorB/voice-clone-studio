import Accelerate
import Foundation

struct VoiceRegion: Identifiable, Sendable {
    var id: String { "\(start)-\(speaker ?? -1)" }
    var start: Double
    var end: Double
    var speaker: Int?
}

struct SignalSnapshot: Sendable {
    let spectrum: [[Double]]
    let regions: [VoiceRegion]
    let elapsedMS: Double
}

/// Reusable Accelerate transform. Instances are confined to the analysis worker.
final class SpectrumTransform {
    let count: Int
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    init(count: Int = 1024) {
        self.count = count
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD)!
        window = (0..<count).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(count - 1))) }
    }
    deinit { vDSP_DFT_DestroySetup(setup) }

    func power(_ samples: [Float], start: Int = 0) -> [Double] {
        var real = [Float](repeating: 0, count: count)
        let imaginary = real
        for index in 0..<count where start + index < samples.count {
            real[index] = samples[start + index] * window[index]
        }
        var outR = real, outI = real
        vDSP_DFT_Execute(setup, real, imaginary, &outR, &outI)
        let scale = Double(count * count)
        var result = [Double]()
        result.reserveCapacity(count / 2)
        for index in 0..<(count / 2) {
            let realPart = Double(outR[index])
            let imaginaryPart = Double(outI[index])
            result.append((realPart * realPart + imaginaryPart * imaginaryPart) / scale)
        }
        return result
    }

    func spectrogram(_ samples: [Float], rate: Double, columns: Int = 240, bins: Int = 48) -> [[Double]] {
        guard samples.count >= count else { return [] }
        return (0..<columns).map { column in
            let start = Int(Double(column) / Double(columns - 1) * Double(samples.count - count))
            let values = power(samples, start: start)
            return (0..<bins).map { bin in
                let low = 70 * pow(min(8000, rate / 2) / 70, Double(bin) / Double(bins))
                let high = 70 * pow(min(8000, rate / 2) / 70, Double(bin + 1) / Double(bins))
                let a = min(values.count - 1, max(1, Int(low / rate * Double(count))))
                let b = min(values.count, max(a + 1, Int(high / rate * Double(count))))
                let value = values[a..<b].max() ?? 0
                return max(0, min(1, (10 * log10(value + 1e-10) + 85) / 65))
            }
        }
    }
}

/// Incremental acoustic grouping, not identity recognition. Unstable windows remain unassigned.
final class OnlineVoiceHints {
    private let transform = SpectrumTransform(count: 512)
    private var prototypes: [[Double]] = []
    private var candidate: [Double]?
    private var candidateRuns = 0

    func classify(_ samples: [Float], sampleRate: Double) -> (speech: Bool, speaker: Int?) {
        guard !samples.isEmpty else { return (false, nil) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms > 0.007 else { candidate = nil; candidateRuns = 0; return (false, nil) }
        let count = Int(Double(samples.count) * 8000 / sampleRate)
        guard count >= 1024 else { return (true, nil) }
        let resampled: [Float] = (0..<count).map { index in
            let source = Double(index) * sampleRate / 8000
            let left = min(samples.count - 1, Int(source))
            let right = min(samples.count - 1, left + 1)
            return samples[left] + Float(source - Double(left)) * (samples[right] - samples[left])
        }
        var cepstra = [[Double]]()
        var periodicities = [Double]()
        for frame in 0..<12 {
            let offset = frame * (resampled.count - 512) / 11
            let power = transform.power(resampled, start: offset)
            let bands = (0..<24).map { index -> Double in
                let low = Int((80 * pow(45, Double(index) / 24)) / 8000 * 512)
                let high = max(low + 1, Int((80 * pow(45, Double(index + 1) / 24)) / 8000 * 512))
                return log((power[low..<min(power.count, high)].reduce(0, +)) + 1e-9)
            }
            let coefficients = (1...12).map { coefficient in
                bands.enumerated().reduce(0.0) { $0 + $1.element * cos(.pi * Double(coefficient) * (Double($1.offset) + 0.5) / 24) }
            }
            cepstra.append(coefficients)
            let slice = Array(resampled[offset..<(offset + 512)])
            let mean = slice.reduce(0, +) / 512
            let centered = slice.map { Double($0 - mean) }
            let energy = centered.reduce(0) { $0 + $1 * $1 }
            var peak = 0.0
            if energy > 0.0001 {
                for lag in stride(from: 20, through: 114, by: 2) {
                    var cross = 0.0
                    for index in 0..<(512 - lag) { cross += centered[index] * centered[index + lag] }
                    peak = max(peak, cross / energy)
                }
            }
            periodicities.append(peak)
        }
        // Broadband noise and ambiguous/nonperiodic sounds should not create a person.
        guard periodicities.filter({ $0 > 0.35 }).count >= 5 else { return (true, nil) }
        var feature = (0..<12).map { index in cepstra.map { $0[index] }.sorted()[6] }
        let norm = sqrt(feature.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return (true, nil) }
        feature = feature.map { $0 / norm }
        let ranked = prototypes.enumerated().map { ($0.offset, distance(feature, $0.element)) }.sorted { $0.1 < $1.1 }
        if let best = ranked.first, best.1 < 0.18,
           ranked.count == 1 || ranked[1].1 - best.1 > 0.035 {
            prototypes[best.0] = zip(prototypes[best.0], feature).map { $0 * 0.96 + $1 * 0.04 }
            candidate = nil; candidateRuns = 0
            return (true, best.0)
        }
        if ranked.first.map({ $0.1 < 0.26 }) == true { return (true, nil) }
        if let candidate, distance(candidate, feature) < 0.12 { candidateRuns += 1 }
        else { candidateRuns = 1 }
        candidate = feature
        if candidateRuns >= 2, prototypes.count < 4 {
            prototypes.append(feature); candidate = nil; candidateRuns = 0
            return (true, prototypes.count - 1)
        }
        return (true, nil)
    }

    private func distance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + $1.0 * $1.1 }
        let norm = sqrt(rhs.reduce(0) { $0 + $1 * $1 })
        return 1 - dot / max(1e-9, norm)
    }
}

/// No Fourier transforms or clustering run on the UI/capture thread.
final class SignalAnalysisWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.signal-analysis", qos: .utility)
    private let transform = SpectrumTransform()
    private var hints = OnlineVoiceHints()
    private var samples: [Float] = []
    private var totalSeconds = 0.0
    private var lastPublication = 0.0
    private var nextVoiceWindowEnd = 0.8
    private var regions: [VoiceRegion] = []

    func append(_ chunk: [Float], rate: Double, capacity: Double, classify: Bool,
                completion: @escaping @Sendable (SignalSnapshot) -> Void) {
        queue.async { [self] in
            let started = Date()
            samples.append(contentsOf: chunk)
            totalSeconds += Double(chunk.count) / rate
            let limit = Int(capacity * rate)
            if samples.count > limit { samples.removeFirst(samples.count - limit) }
            let origin = totalSeconds - Double(samples.count) / rate
            while nextVoiceWindowEnd <= totalSeconds {
                let end = nextVoiceWindowEnd
                let a = max(0, Int((end - 0.8 - origin) * rate))
                let b = min(samples.count, Int((end - origin) * rate))
                if classify, b > a {
                    let result = hints.classify(Array(samples[a..<b]), sampleRate: rate)
                    if result.speech {
                        let start = max(origin, end - 0.4)
                        if let last = regions.last, last.speaker == result.speaker, start - last.end < 0.05 {
                            regions[regions.count - 1].end = end
                        } else { regions.append(VoiceRegion(start: start, end: end, speaker: result.speaker)) }
                    }
                }
                nextVoiceWindowEnd += 0.4
            }
            regions.removeAll { $0.end <= origin }
            guard totalSeconds - lastPublication >= 0.25 else { return }
            lastPublication = totalSeconds
            let spectrum = transform.spectrogram(samples, rate: rate)
            let visible = regions.map { VoiceRegion(start: max(0, $0.start - origin), end: $0.end - origin, speaker: $0.speaker) }
            completion(SignalSnapshot(spectrum: spectrum, regions: visible, elapsedMS: Date().timeIntervalSince(started) * 1000))
        }
    }

    static func file(_ samples: [Float], rate: Double) async -> SignalSnapshot {
        await Task.detached(priority: .utility) {
            let started = Date()
            let spectrum = SpectrumTransform().spectrogram(samples, rate: rate)
            return SignalSnapshot(spectrum: spectrum, regions: [], elapsedMS: Date().timeIntervalSince(started) * 1000)
        }.value
    }
}
