import CoreGraphics
import Foundation

/// Where the operator put each stage and how big they made it. The graph is a workspace,
/// so it has to come back the way it was left — otherwise every launch starts with the same
/// rearranging.
struct NodeLayout: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double?
}

enum GraphLayoutStore {
    private static let key = "voiceStudio.graphLayout"

    static func load() -> [WorkflowNode: NodeLayout] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: NodeLayout].self, from: data)
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            guard let node = WorkflowNode(rawValue: entry.key) else { return }
            result[node] = entry.value
        }
    }

    static func save(positions: [WorkflowNode: CGPoint], sizes: [WorkflowNode: CGSize]) {
        var stored: [String: NodeLayout] = [:]
        for node in WorkflowNode.allCases {
            guard let origin = positions[node] else { continue }
            let size = sizes[node]
            stored[node.rawValue] = NodeLayout(x: origin.x, y: origin.y,
                                               width: Double(size?.width ?? node.width),
                                               height: size.map { Double($0.height) })
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
