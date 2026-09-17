import Foundation

struct LiveTelemetry: Decodable {
    var phase = "listening"
    var inputPackets = 0
    var inputBufferSeconds = 0.0
    var generationLagSeconds = 0.0
    var synthesisSpeed: Double?
    enum CodingKeys: String, CodingKey {
        case phase
        case inputPackets = "input_packets"
        case inputBufferSeconds = "input_buffer_seconds"
        case generationLagSeconds = "generation_lag_seconds"
        case synthesisSpeed = "synthesis_speed"
    }
}

struct LivePhrase: Identifiable {
    let id: Int
    var text = "Recognizing speech…"
    var inputSeconds = 0.0
    var outputSeconds = 0.0
    var generationDone = false
    var state = "Recognizing"
}
