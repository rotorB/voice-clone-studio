import AppKit
import SwiftUI

// The window shows the whole studio at once as a workflow graph: the capture and training
// stage feeds a voice model into the two stages that use it. The menu bar popover keeps
// the tabbed layout — there is no room for a canvas in a 580pt panel.

enum WorkflowNode: String, CaseIterable, Identifiable, Hashable {
    case sample, live, text
    var id: String { rawValue }

    var width: CGFloat {
        switch self {
        case .sample: return 880
        case .live: return 690
        case .text: return 700
        }
    }

    /// A stage can be dragged out to give a list room, but not past the point where its
    /// own rows stop fitting.
    var minimumSize: CGSize {
        switch self {
        case .sample: return CGSize(width: 720, height: 520)
        case .live: return CGSize(width: 560, height: 420)
        case .text: return CGSize(width: 560, height: 420)
        }
    }

    static let defaultPositions: [WorkflowNode: CGPoint] = [
        .sample: CGPoint(x: 300, y: 40),
        .live: CGPoint(x: 30, y: 830),
        .text: CGPoint(x: 800, y: 830),
    ]
}

enum CanvasTool: String { case pointer, hand }

private struct NodeSizeKey: PreferenceKey {
    static let defaultValue: [WorkflowNode: CGSize] = [:]
    static func reduce(value: inout [WorkflowNode: CGSize], nextValue: () -> [WorkflowNode: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct GraphWorkspaceView: View {
    @EnvironmentObject private var model: StudioModel
    @State private var tool: CanvasTool = .pointer
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAtDragStart: CGSize = .zero
    @State private var positions = WorkflowNode.defaultPositions
    @State private var positionAtDragStart: CGPoint?
    @State private var sizes: [WorkflowNode: CGSize] = [:]
    /// Sizes the operator set by dragging a corner. Without an entry a stage is as tall as
    /// its content.
    @State private var overrides: [WorkflowNode: CGSize] = [:]
    @State private var sizeAtDragStart: CGSize?
    @State private var canvasSize: CGSize = .zero
    @State private var hasFitted = false
    @State private var showGrid = true
    @State private var showingDiagnostics = false
    @State private var showingVoiceLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Surface.rule).frame(height: 1)
            canvas
        }
        .background(Surface.canvas)
        .foregroundStyle(Ink.body)
        .tint(Signal.primary)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1120, minHeight: 780)
        .sheet(isPresented: $showingVoiceLibrary) { VoiceLibraryEditor().environmentObject(model) }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Signal.primary)
            HStack(spacing: 8) {
                Text("Voice Studio").font(TypeScale.title).foregroundStyle(Ink.strong)
                Text("Graph workflow").font(TypeScale.title).foregroundStyle(Ink.soft)
            }
            Text("Capture → Train → Use your voice")
                .font(TypeScale.helper).foregroundStyle(Ink.faint).padding(.leading, 4)

            Spacer(minLength: 16)

            toolPicker
            zoomControls
            Button { fitToView() } label: { Image(systemName: "rectangle.center.inset.filled") }
                .buttonStyle(IconButtonStyle()).help("Fit the whole graph in the window")
            Button {
                overrides = [:]
                positions = WorkflowNode.defaultPositions
                GraphLayoutStore.clear()
                fitToView(widthOnly: true)
            } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(IconButtonStyle()).help("Reset the stage positions and sizes")
            Button { showGrid.toggle() } label: { Image(systemName: showGrid ? "grid" : "square") }
                .buttonStyle(IconButtonStyle()).help(showGrid ? "Hide the grid" : "Show the grid")

            Menu {
                ForEach(model.savedVoices) { voice in
                    Button(voice.name) { Task { await model.activateSavedVoice(voice) } }
                }
                if !model.savedVoices.isEmpty { Divider() }
                Button("Manage library…") { showingVoiceLibrary = true }
            } label: {
                MenuChip(title: activeVoiceName, icon: "person.wave.2")
            }
            .studioMenu().fixedSize()
            .disabled(model.isLive || model.isRecording || model.isWorking)

            Button { showingDiagnostics.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle()).help("Engine details")
                .popover(isPresented: $showingDiagnostics) { EngineDetailsView().environmentObject(model) }
            Menu {
                Button("Open output folder") { model.revealOutput() }
                Button("Open web interface") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:7860")!) }
                Divider()
                Button("Quit Voice Studio") { NSApplication.shared.terminate(nil) }
            } label: { MenuIconChip(icon: "ellipsis") }
                .studioMenu().fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Surface.plateHeader)
    }

    private var toolPicker: some View {
        HStack(spacing: 2) {
            toolButton(.pointer, icon: "cursorarrow", help: "Move the stages")
            toolButton(.hand, icon: "hand.raised", help: "Drag the canvas")
        }
        .padding(2)
        .background(Surface.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Surface.ruleStrong))
    }

    private func toolButton(_ value: CanvasTool, icon: String, help: String) -> some View {
        Button { tool = value } label: {
            Image(systemName: icon).font(.system(size: 12))
                .foregroundStyle(tool == value ? Signal.primary : Ink.soft)
                .frame(width: 28, height: 24)
                .background(tool == value ? Signal.primary.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { setZoom(zoom - 0.1) } label: { Image(systemName: "minus") }
                .buttonStyle(.plain).frame(width: 26, height: 24).contentShape(Rectangle())
                .disabled(zoom <= 0.5)
            Text("\(Int((zoom * 100).rounded()))%")
                .font(TypeScale.meta).monospacedDigit().foregroundStyle(Ink.body)
                .frame(width: 44)
            Button { setZoom(zoom + 0.1) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).frame(width: 26, height: 24).contentShape(Rectangle())
                .disabled(zoom >= 2)
        }
        .foregroundStyle(Ink.body)
        .padding(2)
        .background(Surface.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Surface.ruleStrong))
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(2, max(0.5, (value * 10).rounded() / 10))
    }

    /// Frames every stage in the window. Called once the nodes have reported their size,
    /// and again whenever the operator asks for it.
    private func fitToView(widthOnly: Bool = false) {
        guard canvasSize.width > 40, sizes.count == WorkflowNode.allCases.count else { return }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for node in WorkflowNode.allCases {
            guard let origin = positions[node], let size = sizes[node] else { return }
            minX = min(minX, origin.x); minY = min(minY, origin.y)
            maxX = max(maxX, origin.x + size.width); maxY = max(maxY, origin.y + size.height)
        }
        let margin: CGFloat = 28
        let available = CGSize(width: canvasSize.width - margin * 2, height: canvasSize.height - margin * 2)
        let byWidth = available.width / (maxX - minX)
        let scale = widthOnly ? min(1, byWidth) : min(1, min(byWidth, available.height / (maxY - minY)))
        zoom = max(0.5, (scale * 100).rounded() / 100)
        pan = CGSize(width: margin - minX * zoom + max(0, available.width - (maxX - minX) * zoom) / 2,
                     height: margin - minY * zoom)
        panAtDragStart = pan
    }

    private func restoreLayout() {
        let stored = GraphLayoutStore.load()
        guard !stored.isEmpty else { return }
        for (node, layout) in stored {
            positions[node] = CGPoint(x: layout.x, y: layout.y)
            if let height = layout.height {
                overrides[node] = CGSize(width: layout.width, height: height)
            } else if layout.width != node.width {
                overrides[node] = CGSize(width: layout.width, height: 0)
            }
        }
    }

    private func persistLayout() {
        GraphLayoutStore.save(positions: positions, sizes: overrides)
    }

    private func size(of node: WorkflowNode) -> CGSize? {
        guard let override = overrides[node] else { return nil }
        return override
    }

    private var activeVoiceName: String {
        model.savedVoices.first(where: { $0.id == model.activeVoiceID })?.name
        ?? (model.referenceReady ? "Reference ready" : "No voice yet")
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            canvasBody
                .onAppear {
                    canvasSize = proxy.size
                    restoreLayout()
                    fitToView(widthOnly: true)
                }
                .onChange(of: proxy.size) { _, size in
                    canvasSize = size
                    if !hasFitted { fitToView(widthOnly: true) }
                }
        }
    }

    private var canvasBody: some View {
        ZStack(alignment: .topLeading) {
            BlueprintGrid(zoom: zoom, pan: pan).opacity(showGrid ? 1 : 0)
            Color.clear.contentShape(Rectangle()).gesture(panGesture)
            // A zero-sized anchor: the graph is far larger than the window and must not
            // drive the window's own layout.
            nodeLayer
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(pan)
                .frame(width: 0, height: 0, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if positionAtDragStart == nil && panAtDragStart == .zero { panAtDragStart = pan }
                pan = CGSize(width: panAtDragStart.width + value.translation.width,
                             height: panAtDragStart.height + value.translation.height)
            }
            .onEnded { _ in panAtDragStart = pan }
    }

    private var nodeLayer: some View {
        ZStack(alignment: .topLeading) {
            EdgeLayer(positions: positions, sizes: sizes)
            ForEach(WorkflowNode.allCases) { node in
                nodeView(node)
                    .frame(width: size(of: node)?.width ?? node.width)
                    .frame(height: (size(of: node)?.height).flatMap { $0 > 0 ? $0 : nil },
                           alignment: .topLeading)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: NodeSizeKey.self, value: [node: proxy.size])
                    })
                    .environment(\.nodeHasFixedHeight, (size(of: node)?.height ?? 0) > 0)
                    .overlay(alignment: .bottomTrailing) { resizeGrip(node) }
                    .offset(x: positions[node]?.x ?? 0, y: positions[node]?.y ?? 0)
                    .gesture(nodeGesture(node))
            }
        }
        .frame(width: 1800, height: 1500, alignment: .topLeading)
        .onPreferenceChange(NodeSizeKey.self) { measured in
            sizes = measured
            guard !hasFitted, measured.count == WorkflowNode.allCases.count else { return }
            hasFitted = true
            fitToView(widthOnly: true)
        }
    }

    private func nodeGesture(_ node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard tool == .pointer else {
                    if panAtDragStart == .zero { panAtDragStart = pan }
                    pan = CGSize(width: panAtDragStart.width + value.translation.width,
                                 height: panAtDragStart.height + value.translation.height)
                    return
                }
                if positionAtDragStart == nil { positionAtDragStart = positions[node] }
                guard let origin = positionAtDragStart else { return }
                positions[node] = CGPoint(x: origin.x + value.translation.width / zoom,
                                          y: origin.y + value.translation.height / zoom)
            }
            .onEnded { _ in
                if positionAtDragStart != nil { persistLayout() }
                positionAtDragStart = nil
                panAtDragStart = pan
            }
    }

    /// The corner handle. Dragging it sets an explicit size for that stage; double-clicking
    /// gives the stage back to its content.
    private func resizeGrip(_ node: WorkflowNode) -> some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Ink.faint)
            .frame(width: 18, height: 18)
            .background(Surface.control, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Surface.ruleStrong))
            .padding(6)
            .contentShape(Rectangle())
            .gesture(resizeGesture(node))
            .onTapGesture(count: 2) {
                overrides[node] = nil
                persistLayout()
            }
            .help("Drag to resize this stage · double-click to fit its content")
    }

    private func resizeGesture(_ node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if sizeAtDragStart == nil {
                    sizeAtDragStart = overrides[node] ?? sizes[node]
                        ?? CGSize(width: node.width, height: node.minimumSize.height)
                }
                guard let start = sizeAtDragStart else { return }
                let minimum = node.minimumSize
                overrides[node] = CGSize(
                    width: max(minimum.width, min(1800, start.width + value.translation.width / zoom)),
                    height: max(minimum.height, min(1400, start.height + value.translation.height / zoom))
                )
            }
            .onEnded { _ in
                sizeAtDragStart = nil
                persistLayout()
            }
    }

    @ViewBuilder
    private func nodeView(_ node: WorkflowNode) -> some View {
        switch node {
        case .sample: SampleStageNode()
        case .live: LiveStageNode()
        case .text: TextStageNode()
        }
    }
}

// MARK: - Canvas furniture

struct BlueprintGrid: View {
    let zoom: CGFloat
    let pan: CGSize

    var body: some View {
        Canvas { context, size in
            let minor = max(8, 26 * zoom)
            let major = minor * 4
            for (spacing, color) in [(minor, Graph.gridMinor), (major, Graph.gridMajor)] {
                var x = pan.width.truncatingRemainder(dividingBy: spacing)
                if x > 0 { x -= spacing }
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
                    x += spacing
                }
                var y = pan.height.truncatingRemainder(dividingBy: spacing)
                if y > 0 { y -= spacing }
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(color))
                    y += spacing
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The amber links that carry the trained voice model to the two stages that consume it.
struct EdgeLayer: View {
    let positions: [WorkflowNode: CGPoint]
    let sizes: [WorkflowNode: CGSize]

    var body: some View {
        Canvas { context, _ in
            guard let source = positions[.sample], let sourceSize = sizes[.sample] else { return }
            for (target, sourceFraction, targetFraction) in [(WorkflowNode.live, 0.34, 0.56),
                                                             (WorkflowNode.text, 0.66, 0.44)] {
                guard let end = positions[target], let endSize = sizes[target] else { continue }
                let start = CGPoint(x: source.x + sourceSize.width * sourceFraction,
                                    y: source.y + sourceSize.height)
                let finish = CGPoint(x: end.x + endSize.width * targetFraction, y: end.y)
                draw(&context, from: start, to: finish)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ context: inout GraphicsContext, from start: CGPoint, to finish: CGPoint) {
        let reach = max(70, (finish.y - start.y) * 0.55)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: finish,
                      control1: CGPoint(x: start.x, y: start.y + reach),
                      control2: CGPoint(x: finish.x, y: finish.y - reach))
        let flow = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Graph.edgeFrom, Graph.edgeTo]),
            startPoint: start, endPoint: finish)
        context.stroke(path, with: flow, lineWidth: 1.8)

        for (point, tint) in [(start, Graph.edgeFrom), (finish, Graph.edgeTo)] {
            let dot = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: dot), with: .color(Surface.canvas))
            context.stroke(Path(ellipseIn: dot), with: .color(tint), lineWidth: 1.8)
        }

        // Midpoint of the cubic, so the label sits on the link rather than beside it.
        let middle = CGPoint(x: (start.x + 3 * start.x + 3 * finish.x + finish.x) / 8,
                             y: (start.y + 3 * (start.y + reach) + 3 * (finish.y - reach) + finish.y) / 8)
        var label = context.resolve(Text("Voice model").font(TypeScale.helper))
        label.shading = .color(Graph.edgeFrom)
        let textSize = label.measure(in: CGSize(width: 200, height: 40))
        let plate = CGRect(x: middle.x - textSize.width / 2 - 7, y: middle.y - textSize.height / 2 - 3,
                           width: textSize.width + 14, height: textSize.height + 6)
        context.fill(Path(roundedRect: plate, cornerRadius: 5), with: .color(Surface.canvas))
        context.draw(label, at: middle, anchor: .center)
    }
}

// MARK: - Node chrome

/// True for a stage the operator gave an explicit height, so its content should fill it.
private struct NodeFixedHeightKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var nodeHasFixedHeight: Bool {
        get { self[NodeFixedHeightKey.self] }
        set { self[NodeFixedHeightKey.self] = newValue }
    }
}

struct NodeCard<Content: View>: View {
    @Environment(\.nodeHasFixedHeight) private var hasFixedHeight
    let title: String
    let subtitle: String
    var trailing: AnyView?
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = nil
        self.content = content()
    }

    init<T: View>(_ title: String, subtitle: String,
                  @ViewBuilder trailing: () -> T, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Graph.nodeMark).frame(width: 9, height: 9)
                Text(title).font(TypeScale.title).foregroundStyle(Ink.strong)
                Spacer(minLength: 16)
                Text(subtitle).font(TypeScale.helper).foregroundStyle(Ink.soft).lineLimit(1)
                if let trailing { trailing }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Surface.plateHeader)
            Rectangle().fill(Surface.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(14)
                // Only a stage the operator resized may stretch: inside the canvas a card
                // with no height of its own would grow to the whole 1500pt layer.
                .frame(maxWidth: .infinity,
                       maxHeight: hasFixedHeight ? .infinity : nil,
                       alignment: .topLeading)
        }
        .background(Surface.plate, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Surface.rule))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }
}

/// A numbered stage inside a node. The numbers are real: each one only makes sense after
/// the one before it.
struct StageLabel: View {
    let index: Int
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Text("\(index).").font(TypeScale.label).foregroundStyle(Ink.faint)
            Text(title).font(TypeScale.label).foregroundStyle(Ink.body)
        }
    }
}

struct NodeBox<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))
    }
}

struct ChoiceChip: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(TypeScale.label).lineLimit(1)
            }
            .foregroundStyle(selected ? Signal.primary : Ink.body)
            .padding(.horizontal, 10).frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(selected ? Signal.primary.opacity(0.12) : Surface.control,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Signal.primary.opacity(0.55) : Surface.rule))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

enum StageState { case waiting, running, done }

struct PipelineStage: View {
    let title: String
    let state: StageState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            Text(title).font(TypeScale.label).foregroundStyle(state == .waiting ? Ink.soft : Ink.strong)
                .lineLimit(1)
        }
        .padding(.horizontal, 11).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(state == .running ? Signal.primary.opacity(0.5) : Surface.rule))
    }

    private var symbol: String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .running: return "circle.dotted"
        case .waiting: return "circle"
        }
    }

    private var tint: Color {
        switch state {
        case .done: return Signal.ready
        case .running: return Signal.primary
        case .waiting: return Ink.faint
        }
    }
}

struct PipelineArrow: View {
    var body: some View {
        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Ink.faint)
    }
}

/// One measured line in a readout table: name, value, and an optional state dot.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color = Ink.strong
    var dot: Color?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(TypeScale.helper).foregroundStyle(Ink.soft).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(TypeScale.value).monospacedDigit().foregroundStyle(tint).lineLimit(1)
            if let dot { StateDot(color: dot, size: 6) }
        }
    }
}

struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(TypeScale.helper).foregroundStyle(Ink.soft)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Ink.strong)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared by the popover and the canvas.
struct EngineDetailsView: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Engine")
            Text(model.backend.status).font(TypeScale.body).foregroundStyle(Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            PlateRule()
            StatRow(label: "Health response", value: model.backend.healthLatencyMS.map { "\($0) ms" } ?? "—")
            StatRow(label: "Traffic", value: String(format: "%.1f KB/s", model.backend.healthSnapshot?.trafficKBPS ?? 0))
            StatRow(label: "Signal analysis", value: String(format: "%.1f ms per update", model.analysisMS))
            StatRow(label: "Detected language", value: model.detectedLanguage)
            PlateRule()
            HStack(spacing: 8) {
                Button("Open the log") { model.revealBackendLog() }.buttonStyle(SecondaryButtonStyle())
                Button("Restart the engine") { Task { await model.restartBackend() } }
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.isRestartingBackend)
            }
        }.padding(16).frame(width: 320)
    }
}
