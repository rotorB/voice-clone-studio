import AppKit
import SwiftUI

// The three stages of the graph. Each one is an ordinary SwiftUI view; the canvas only
// positions them and draws the links between them.

func chooseAudioSample(into model: StudioModel) {
    let picker = NSOpenPanel()
    picker.title = "Choose a voice sample"
    picker.allowedContentTypes = [.audio]
    picker.allowsMultipleSelection = false
    picker.canChooseDirectories = false
    picker.level = .floating
    NSApplication.shared.activate(ignoringOtherApps: true)
    picker.begin { response in if response == .OK, let url = picker.url { model.loadFile(url) } }
}

func clockText(_ seconds: Double) -> String {
    let whole = Int(max(0, seconds))
    return String(format: "%02d:%02d", whole / 60, whole % 60)
}

func decibelText(_ level: Double) -> String {
    guard level > 0.0005 else { return "—" }
    return String(format: "%.0f dB", 20 * log10(min(1, level)))
}

// MARK: - Stage 1

struct SampleStageNode: View {
    @EnvironmentObject private var model: StudioModel
    @State private var scope: ScopeMode = .spectrogram

    var body: some View {
        NodeCard("Sample capture & voice training",
                 subtitle: "Build a voice model from your audio") {
            captureRow
            scopeBox
            selectionBar
            pipelineRow
            resultRow
        }
    }

    // 1 / 2 / 3 — source, record, signal check.
    private var captureRow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                StageLabel(index: 1, title: "Audio source")
                HStack(spacing: 8) {
                    ChoiceChip(title: "Microphone", icon: "mic",
                               selected: model.captureSource != .system) { model.captureSource = .microphone }
                    ChoiceChip(title: "System audio", icon: "display",
                               selected: model.captureSource == .system) { model.captureSource = .system }
                }
                Menu {
                    ForEach(model.inputDevices) { device in
                        Button(device.name) { model.selectInput(device.id) }
                    }
                    Divider()
                    Button("Refresh microphones") { model.refreshInputs() }
                } label: {
                    MenuChip(title: selectedInputName, icon: "mic", fills: true)
                }.studioMenu()
                HStack(spacing: 8) {
                    Menu {
                        ForEach([10, 20, 30, 60], id: \.self) { value in
                            Button("Keep the last \(value) seconds") { model.recordingBufferSeconds = Double(value) }
                        }
                    } label: { MenuChip(title: "Keep last \(Int(model.recordingBufferSeconds)) s") }
                        .studioMenu().fixedSize()
                    Button { chooseAudioSample(into: model) } label: { Image(systemName: "folder") }
                        .buttonStyle(IconButtonStyle()).help("Load an audio file")
                    Spacer(minLength: 0)
                }
            }
            .padding(12).frame(width: Self.sourceCellWidth, alignment: .topLeading)
            .disabled(model.isRecording)


            VStack(alignment: .leading, spacing: 10) {
                StageLabel(index: 2, title: "Record audio")
                HStack(spacing: 12) {
                    Button {
                        if !model.isRecording { Task { await model.startRecording() } }
                    } label: {
                        ZStack {
                            Circle().fill(Signal.live.opacity(model.isRecording ? 0.25 : 1))
                            if model.isRecording {
                                Circle().strokeBorder(Signal.live, lineWidth: 2)
                            }
                        }.frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain).disabled(model.isRecording || model.isWorking)
                    .help("Start recording")

                    Button { model.stopRecording() } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(model.isRecording ? Ink.strong : Ink.faint)
                            .frame(width: 14, height: 14)
                            .frame(width: 34, height: 34)
                            .background(Surface.control, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Surface.ruleStrong))
                    }
                    .buttonStyle(.plain).disabled(!model.isRecording).help("Stop recording")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(clockText(model.duration))
                            .font(.system(size: 19, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Ink.strong)
                        Text(model.isRecording ? "Recording…" : model.duration > 0 ? "Captured" : "Nothing yet")
                            .font(TypeScale.helper)
                            .foregroundStyle(model.isRecording ? Signal.live : Ink.soft)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 5) {
                        LevelColumn(level: model.sampleInputLevel).frame(width: 16, height: 46)
                        Text(decibelText(model.sampleInputLevel))
                            .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.soft)
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)


            VStack(alignment: .leading, spacing: 9) {
                StageLabel(index: 3, title: "Signal check")
                StatRow(label: "Duration", value: String(format: "%.1f s", model.duration),
                        dot: model.duration > 0 ? Signal.ready : Ink.faint)
                StatRow(label: "Selected", value: String(format: "%.1f s", selectionLength),
                        dot: selectionLength >= 6 ? Signal.ready : selectionLength >= 1 ? Signal.warn : Ink.faint)
                StatRow(label: "Voices found", value: "\(voiceCount)",
                        dot: voiceCount == 1 ? Signal.ready : voiceCount > 1 ? Signal.warn : Ink.faint)
                StatRow(label: "Peak", value: decibelText(model.sampleInputLevel),
                        dot: model.sampleInputLevel > 0.94 ? Signal.live : nil)
            }
            .padding(12).frame(width: Self.checkCellWidth, alignment: .topLeading)
        }
        .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 9))
        .overlay(cellRules)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))
    }

    private var cellRules: some View {
        GeometryReader { proxy in
            Path { path in
                for x in [Self.sourceCellWidth, proxy.size.width - Self.checkCellWidth] {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                }
            }.stroke(Surface.rule, lineWidth: 1)
        }
    }

    static let sourceCellWidth: CGFloat = 292
    static let checkCellWidth: CGFloat = 238

    private var scopeBox: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                scopeTab("Waveform", value: .waveform)
                scopeTab("Spectrogram", value: .spectrogram)
                Spacer(minLength: 12)
                Text("Drag across the view to select")
                    .font(TypeScale.helper).foregroundStyle(Ink.faint).padding(.trailing, 12)
            }
            .background(Surface.plateHeader)
            Rectangle().fill(Surface.rule).frame(height: 1)
            SampleScope(mode: scope, spectrum: model.spectrum, samples: model.samples,
                        duration: model.duration,
                        start: $model.selectionStart, end: $model.selectionEnd,
                        playhead: model.playhead, regions: displayedRegions,
                        editable: !model.isRecording)
                .frame(height: 132)
        }
        .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func scopeTab(_ title: String, value: ScopeMode) -> some View {
        Button { scope = value } label: {
            Text(title).font(TypeScale.label)
                .foregroundStyle(scope == value ? Signal.primary : Ink.soft)
                .padding(.horizontal, 14).frame(height: 32)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(scope == value ? Signal.primary : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(model.duration > 0
                 ? String(format: "Selected %.2f – %.2f s", model.selectionStart, model.selectionEnd)
                 : "Nothing loaded yet")
                .font(TypeScale.meta).monospacedDigit().foregroundStyle(Ink.body).lineLimit(1)
            voiceChips
            Spacer(minLength: 8)
            Button("Select all") { model.selectionStart = 0; model.selectionEnd = model.duration }
                .buttonStyle(QuietButtonStyle()).disabled(model.isRecording || model.duration == 0)
            Button { model.playSelection() } label: {
                Label(model.isAuditioning ? "Stop" : "Audition",
                      systemImage: model.isAuditioning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle()).disabled(model.duration == 0 || model.isRecording)
            Button { Task { await model.prepareSelection() } } label: {
                Text(model.isWorking ? "Preparing…" : "Use this selection")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isRecording || model.isWorking || selectionLength < 1)
        }
    }

    private var voiceChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(Set(displayedRegions.compactMap(\.speaker))).sorted(), id: \.self) { speaker in
                let regions = displayedRegions.filter { $0.speaker == speaker }
                Button {
                    if let longest = regions.max(by: { $0.end - $0.start < $1.end - $1.start }) {
                        model.selectionStart = longest.start; model.selectionEnd = longest.end
                    }
                } label: {
                    HStack(spacing: 5) {
                        StateDot(color: speakerTint(speaker), size: 6)
                        Text("Voice \(String(UnicodeScalar(65 + speaker)!))")
                            .font(TypeScale.helper).foregroundStyle(Ink.body)
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Surface.rule))
                }
                .buttonStyle(.plain).disabled(model.isRecording)
                .help("Select the longest stretch of this voice")
            }
        }
    }

    private var pipelineRow: some View {
        HStack(spacing: 10) {
            Text("Processing pipeline").font(TypeScale.label).foregroundStyle(Ink.soft)
                .frame(width: 132, alignment: .leading)
            PipelineStage(title: "1. Capture", state: model.duration > 0 ? .done : model.isRecording ? .running : .waiting)
            PipelineArrow()
            PipelineStage(title: "2. Transcribe", state: model.transcript.isEmpty ? (model.isWorking ? .running : .waiting) : .done)
            PipelineArrow()
            PipelineStage(title: "3. Train voice model", state: model.referenceReady ? .done : model.isWorking ? .running : .waiting)
        }
    }

    private var resultRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Transcript").font(TypeScale.label).foregroundStyle(Ink.body)
                    Spacer()
                    if !model.transcript.isEmpty {
                        Button("Apply") { Task { await model.saveTranscript() } }
                            .buttonStyle(QuietButtonStyle()).disabled(model.isWorking || model.isRecording)
                    }
                }
                TextEditor(text: $model.transcript)
                    .font(TypeScale.body).foregroundStyle(Ink.strong).scrollContentBackground(.hidden)
                    .frame(height: 78).padding(7)
                    .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Surface.rule))
                    .overlay(alignment: .topLeading) {
                        if model.transcript.isEmpty {
                            Text("What the reference says, once it is recognised.")
                                .font(TypeScale.helper).foregroundStyle(Ink.faint)
                                .padding(.horizontal, 11).padding(.vertical, 11).allowsHitTesting(false)
                        }
                    }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 9) {
                Text("Training status").font(TypeScale.label).foregroundStyle(Ink.body)
                NodeBox(padding: 11) {
                    StatRow(label: "Reference", value: model.referenceReady ? "Trained" : "Not yet",
                            tint: model.referenceReady ? Signal.ready : Ink.soft)
                    StatRow(label: "Language", value: model.detectedLanguage)
                    StatRow(label: "Saved voices", value: "\(model.savedVoices.count)")
                    StatRow(label: "Separation", value: separationTitle)
                }
            }
            .frame(width: 208)

            VStack(alignment: .leading, spacing: 9) {
                Text("Voice library").font(TypeScale.label).foregroundStyle(Ink.body)
                NodeBox(padding: 11) {
                    HStack(spacing: 6) {
                        Image(systemName: model.referenceReady ? "checkmark.circle.fill" : "clock")
                            .font(.system(size: 13))
                            .foregroundStyle(model.referenceReady ? Signal.ready : Signal.warn)
                        Text(model.referenceReady ? "Voice model ready" : "Waiting for a reference")
                            .font(TypeScale.value)
                            .foregroundStyle(model.referenceReady ? Signal.ready : Ink.body)
                    }
                    Text(model.sampleStatus).font(TypeScale.helper).foregroundStyle(Ink.soft)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                    HStack(spacing: 8) {
                        TextField("Name this voice", text: $model.voiceName).studioField()
                        Button("Save") { Task { await model.saveCurrentVoice() } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!model.referenceReady || model.isWorking
                                      || model.voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(width: 250)
        }
    }

    private var displayedRegions: [VoiceRegion] {
        if !model.voices.isEmpty {
            return model.voices.enumerated().flatMap { index, voice in
                voice.segments.map { VoiceRegion(start: $0.start, end: $0.end, speaker: index) }
            } + model.mixed.map { VoiceRegion(start: $0.start, end: $0.end, speaker: nil) }
        }
        return model.voiceRegions
    }

    private var voiceCount: Int { Set(displayedRegions.compactMap(\.speaker)).count }
    private var selectionLength: Double { max(0, model.selectionEnd - model.selectionStart) }
    private var selectedInputName: String {
        model.captureSource == .system ? "System audio"
        : model.inputDevices.first(where: { $0.id == model.selectedInput })?.name ?? "Microphone"
    }
    private var separationTitle: String { model.speakerMode.prefix(1).uppercased() + model.speakerMode.dropFirst() }
}

// MARK: - Stage 2

struct LiveStageNode: View {
    @EnvironmentObject private var model: StudioModel

    var body: some View {
        NodeCard("Live mode", subtitle: "Speak and hear in real time", trailing: {
            StatusPill(title: liveSignal, color: liveColor)
        }) {
            HStack(alignment: .top, spacing: 12) {
                settingsColumn.frame(width: 250)
                monitorColumn.frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                StatusLine(text: model.liveStatus, ready: model.referenceReady)
                Spacer(minLength: 10)
                Button { Task { await model.toggleLive() } } label: {
                    Label(model.isLive ? "Stop live" : "Start live",
                          systemImage: model.isLive ? "stop.fill" : "waveform.badge.mic")
                }
                .buttonStyle(PrimaryButtonStyle(tint: model.isLive ? Signal.liveFill : Signal.primaryFill))
                .disabled(!model.referenceReady && !model.isLive)
            }
        }
    }

    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            StageLabel(index: 1, title: "Input source")
            HStack(spacing: 8) {
                ChoiceChip(title: "Microphone", icon: "mic",
                           selected: model.liveSource != .system) { model.liveSource = .microphone }
                ChoiceChip(title: "System audio", icon: "display",
                           selected: model.liveSource == .system) { model.liveSource = .system }
            }
            Menu {
                ForEach(model.inputDevices) { device in Button(device.name) { model.selectInput(device.id) } }
                Divider()
                Button("Refresh microphones") { model.refreshInputs() }
            } label: { MenuChip(title: selectedInputName, icon: "mic", fills: true) }
                .studioMenu()
            Menu {
                ForEach(model.outputDevices) { device in Button(device.name) { model.selectOutput(device.id) } }
                Divider()
                Button("Refresh devices") { model.refreshOutputs() }
            } label: { MenuChip(title: selectedOutputName, icon: "speaker.wave.2", fills: true) }
                .studioMenu()

            StageLabel(index: 2, title: "Recognition").padding(.top, 2)
            FieldRow(label: "Phrase ends") {
                Menu {
                    Button("A finished sentence") { model.endpointMode = "sentence" }
                    Button("A 420 ms pause") { model.endpointMode = "pause"; model.pauseSeconds = 0.42 }
                    Button("A 550 ms pause") { model.endpointMode = "pause"; model.pauseSeconds = 0.55 }
                    Button("A 750 ms pause") { model.endpointMode = "pause"; model.pauseSeconds = 0.75 }
                } label: { MenuChip(title: pauseTitle) }
                    .studioMenu().fixedSize()
            }
            FieldRow(label: "Translate") {
                Toggle("", isOn: $model.translatorEnabled).toggleStyle(.switch)
                    .controlSize(.small).labelsHidden()
            }
            if model.translatorEnabled {
                FieldRow(label: "From") { languageMenu($model.translationSource) }
                FieldRow(label: "Into") { languageMenu($model.translationTarget) }
            } else {
                FieldRow(label: "Language") { languageMenu($model.recognitionLanguage) }
            }
        }
        .disabled(model.isLive)
    }

    private var monitorColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live input").font(TypeScale.label).foregroundStyle(Ink.body)
                Spacer()
                HStack(spacing: 5) {
                    StateDot(color: model.isLive ? Signal.ready : Ink.faint, size: 6)
                    Text(model.isLive ? "Listening" : "Standby")
                        .font(TypeScale.helper).foregroundStyle(Ink.soft)
                }
            }
            LevelHistory(values: model.liveLevels, active: model.isLive)
                .frame(height: 62).padding(.horizontal, 10).padding(.vertical, 8)
                .background(Surface.scope, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))

            Text("Processing chain").font(TypeScale.label).foregroundStyle(Ink.soft)
            HStack(spacing: 8) {
                PipelineStage(title: "Recognise", state: model.telemetry.phase == "recognizing" ? .running : model.isLive ? .done : .waiting)
                PipelineArrow()
                PipelineStage(title: "Synthesise", state: model.telemetry.phase == "synthesizing" ? .running : .waiting)
                PipelineArrow()
                PipelineStage(title: "Play output", state: model.queuedPhraseIDs.isEmpty ? .waiting : .running)
            }

            Text("Heard just now").font(TypeScale.label).foregroundStyle(Ink.soft)
            Text(model.liveTranscript == "—" ? "Nothing yet." : model.liveTranscript)
                .font(TypeScale.body)
                .foregroundStyle(model.liveTranscript == "—" ? Ink.faint : Ink.strong)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10).frame(height: 62, alignment: .topLeading)
                .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))

            HStack(spacing: 12) {
                MiniStat(label: "Behind", value: String(format: "%.1f s", model.telemetry.generationLagSeconds))
                MiniStat(label: "Buffered", value: String(format: "%.1f s", model.telemetry.inputBufferSeconds))
                MiniStat(label: "Queued", value: "\(model.queuedPhraseIDs.count)")
                MiniStat(label: "Tempo", value: String(format: "%.2f×", model.actualTempo))
            }
            HStack(spacing: 10) {
                Slider(value: $model.liveTempo, in: 0.8...1.5).controlSize(.small)
                    .accessibilityLabel("Base speech tempo")
                Toggle("Catch up", isOn: $model.automaticTempo).toggleStyle(.switch)
                    .controlSize(.small).font(TypeScale.helper).foregroundStyle(Ink.soft).fixedSize()
            }
        }
    }

    private func languageMenu(_ value: Binding<String>) -> some View {
        Menu {
            ForEach(liveLanguages, id: \.self) { language in
                Button(language) { value.wrappedValue = language }
            }
        } label: { MenuChip(title: value.wrappedValue) }
            .studioMenu().fixedSize()
    }

    private var selectedInputName: String {
        model.liveSource == .system ? "System audio"
        : model.inputDevices.first(where: { $0.id == model.selectedInput })?.name ?? "Microphone"
    }
    private var selectedOutputName: String {
        model.outputDevices.first(where: { $0.id == model.selectedOutput })?.name ?? "System output"
    }
    private var pauseTitle: String {
        model.endpointMode == "sentence" ? "A sentence" : "\(Int(model.pauseSeconds * 1000)) ms"
    }
    private var lagColor: Color { model.telemetry.generationLagSeconds > 5 ? Signal.warn : Signal.ready }
    private var liveColor: Color {
        model.liveState == "ERROR" ? Signal.live : model.isLive ? lagColor : Ink.soft
    }
    private var liveSignal: String {
        if model.liveState == "ERROR" { return "Error" }
        if !model.isLive { return "Standby" }
        return model.telemetry.generationLagSeconds > 5 ? "Catching up" : "Live"
    }
}

let liveLanguages = ["Auto", "Russian", "English", "Spanish", "German", "French",
                     "Italian", "Portuguese", "Chinese", "Japanese", "Korean"]

// MARK: - Stage 3

struct TextStageNode: View {
    @EnvironmentObject private var model: StudioModel
    /// While the operator drags the progress bar the slider follows the finger, not the
    /// render clock; the seek happens once, on release.
    @State private var scrub: Double?
    /// Collapsed by default: a take uses the delivery the model itself infers from the
    /// reference, and the controls only matter when someone wants to override that.
    @AppStorage("voiceStudio.intonationExpanded") private var showIntonation = false

    var body: some View {
        NodeCard("Text mode", subtitle: "Type text, shape the delivery, synthesise") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    StageLabel(index: 1, title: "Text input")
                    editor
                    intonationHeader
                    if showIntonation { intonationBox }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    StageLabel(index: 3, title: "Generate")
                    Button { Task { await model.generateText() } } label: {
                        Label(model.isWorking ? "Generating…" : "Generate voice", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.referenceReady || model.isWorking
                              || model.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear the text") { model.typedText = "" }
                        .buttonStyle(SecondaryButtonStyle()).frame(maxWidth: .infinity)
                        .disabled(model.typedText.isEmpty)
                    Button { model.revealOutput() } label: {
                        Label("Open output folder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(SecondaryButtonStyle())
                    HStack(spacing: 8) {
                        PipelineStage(title: "Text", state: model.typedText.isEmpty ? .waiting : .done)
                        PipelineArrow()
                        PipelineStage(title: "Voice", state: model.isWorking ? .running : model.tracks.isEmpty ? .waiting : .done)
                    }
                    StatusLine(text: model.generationStatus, ready: model.referenceReady)
                }
                .frame(width: 212)
            }

            takesHeader
            transportBar
            takesList
        }
    }

    // MARK: - Text

    private var editor: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $model.typedText)
                .font(.system(size: 14)).foregroundStyle(Ink.strong)
                .scrollContentBackground(.hidden)
                .padding(10).padding(.bottom, 12)
                .overlay(alignment: .topLeading) {
                    if model.typedText.isEmpty {
                        Text("Type or paste the line you want to hear.")
                            .font(.system(size: 14)).foregroundStyle(Ink.faint)
                            .padding(15).allowsHitTesting(false)
                    }
                }
            Text("\(model.typedText.count) / 2000")
                .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.faint)
                .padding(9)
        }
        .frame(minHeight: 96, maxHeight: .infinity)
        .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))
        .onChange(of: model.typedText) { _, text in
            if text.count > 2000 { model.typedText = String(text.prefix(2000)) }
        }
    }

    // MARK: - Intonation

    /// Emotion, pace and pitch are applied to the finished take; variation changes the
    /// sampling temperature, so it changes what the model says, not just how it sounds.
    private var intonationHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showIntonation.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showIntonation ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.faint)
                    Text("2.").font(TypeScale.label).foregroundStyle(Ink.faint)
                    Text("Intonation").font(TypeScale.label).foregroundStyle(Ink.body)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(model.delivery.isNeutral ? "As the model reads it" : model.delivery.summary)
                .font(TypeScale.helper)
                .foregroundStyle(model.delivery.isNeutral ? Ink.faint : Signal.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !model.delivery.isNeutral {
                Button("Reset") { model.resetDelivery() }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var intonationBox: some View {
        NodeBox {
            HStack(spacing: 10) {
                Menu {
                    ForEach(Delivery.emotions, id: \.self) { name in
                        Button(name) {
                            model.delivery.emotion = name
                            model.persistDelivery()
                        }
                    }
                } label: { MenuChip(title: model.delivery.emotion, icon: "theatermasks", fills: true) }
                    .studioMenu()
                Button("Reset") { model.resetDelivery() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.delivery.isNeutral)
            }
            knobRow("Strength", value: $model.delivery.strength, range: 0...1,
                    format: "\(Int(model.delivery.strength * 100)) %")
                .disabled(model.delivery.emotion == "As in the reference")
            knobRow("Pace", value: $model.delivery.pace, range: 0.6...1.6,
                    format: String(format: "%.2f×", model.delivery.pace))
            knobRow("Pitch", value: $model.delivery.pitch, range: -6...6,
                    format: String(format: "%+.1f st", model.delivery.pitch))
            knobRow("Variation", value: $model.delivery.variation, range: 0.1...1.5,
                    format: String(format: "%.2f", model.delivery.variation))
            Text(model.delivery.isNeutral ? "Nothing applied — the take keeps the delivery the model infers."
                                           : model.delivery.summary)
                .font(TypeScale.helper).foregroundStyle(Ink.soft).lineLimit(1)
        }
    }

    private func knobRow(_ label: String, value: Binding<Double>,
                         range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(TypeScale.label).foregroundStyle(Ink.body)
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing { model.persistDelivery() }
            }
            .controlSize(.small)
            Text(format).font(TypeScale.value).monospacedDigit()
                .foregroundStyle(Ink.strong).frame(width: 62, alignment: .trailing)
        }
    }

    // MARK: - Takes and playback

    private var takesHeader: some View {
        HStack(spacing: 10) {
            StageLabel(index: 4, title: "Takes & playback")
            Text(model.tracks.isEmpty ? "Nothing generated yet" : "\(model.tracks.count) on disk")
                .font(TypeScale.helper).foregroundStyle(Ink.faint)
            Spacer(minLength: 8)
            Text("Play through").font(TypeScale.helper).foregroundStyle(Ink.soft)
            Menu {
                Button("System output") { model.selectPlaybackDevice(nil) }
                if !model.outputDevices.isEmpty { Divider() }
                ForEach(model.outputDevices) { device in
                    Button(device.name) { model.selectPlaybackDevice(device.id) }
                }
                Divider()
                Button("Refresh devices") { model.refreshOutputs() }
            } label: {
                MenuChip(title: model.playbackDeviceName, icon: "speaker.wave.2")
            }
            .studioMenu().fixedSize()
            .help("Takes play through this device only — the system output is left alone")
        }
    }

    @ViewBuilder
    private var transportBar: some View {
        if let id = model.playingTrack {
            HStack(spacing: 10) {
                Button { model.toggleTrackPause() } label: {
                    Image(systemName: model.isTrackPaused ? "play.fill" : "pause.fill")
                }.buttonStyle(IconButtonStyle()).help(model.isTrackPaused ? "Resume" : "Pause")
                Button { model.stopTrack() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(IconButtonStyle()).help("Stop")
                Text(clockText(scrub ?? model.trackElapsed))
                    .font(TypeScale.value).monospacedDigit().foregroundStyle(Ink.strong)
                Slider(value: Binding(get: { min(scrub ?? model.trackElapsed, model.trackDuration) },
                                      set: { scrub = $0 }),
                       in: 0...max(0.1, model.trackDuration)) { editing in
                    if !editing, let target = scrub {
                        model.seekTrack(to: target)
                        scrub = nil
                    }
                }
                .controlSize(.small)
                Text(clockText(model.trackDuration))
                    .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.soft)
                Text(playingTitle(id)).font(TypeScale.helper).foregroundStyle(Ink.soft)
                    .lineLimit(1).frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Surface.rule))
        }
    }

    private var takesList: some View {
        NodeBox(padding: 0) {
            if model.tracks.isEmpty {
                Text("Generated audio collects here, newest first.")
                    .font(TypeScale.helper).foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.tracks) { track in
                            trackRow(track)
                            if track.id != model.tracks.last?.id { PlateRule() }
                        }
                    }
                }
                .frame(minHeight: 96, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 96, maxHeight: .infinity)
    }

    private func trackRow(_ track: TextTrack) -> some View {
        HStack(spacing: 10) {
            Button { Task { await model.play(track) } } label: {
                Image(systemName: model.playingTrack == track.id ? "stop.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help(model.playingTrack == track.id ? "Stop" : "Play this take")
            VStack(alignment: .leading, spacing: 2) {
                Text(track.text).font(TypeScale.body).foregroundStyle(Ink.strong).lineLimit(1)
                Text(String(format: "%.1f s long, made in %.2f s", track.audio.duration, track.audio.elapsed))
                    .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.soft)
            }
            Spacer(minLength: 8)
            if model.playingTrack == track.id {
                StatusPill(title: model.isTrackPaused ? "Paused" : "Playing",
                           color: model.isTrackPaused ? Signal.warn : Signal.primary)
            }
            Button { model.reveal(track) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(Ink.faint).help("Show in Finder")
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func playingTitle(_ id: String) -> String {
        model.tracks.first(where: { $0.id == id })?.text ?? id
    }
}

// MARK: - Meters

/// Vertical segmented meter next to the record button.
struct LevelColumn: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            let segments = 9
            let gap: CGFloat = 2
            let unit = (proxy.size.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
            VStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { index in
                    let threshold = Double(segments - index) / Double(segments)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level >= threshold - 0.001 ? tint(threshold) : Surface.rule)
                        .frame(height: max(2, unit))
                }
            }
        }.accessibilityLabel("Input level").accessibilityValue("\(Int(level * 100)) percent")
    }

    private func tint(_ threshold: Double) -> Color {
        threshold > 0.88 ? Signal.live : threshold > 0.66 ? Signal.warn : Signal.ready
    }
}

// MARK: - Scope

enum ScopeMode { case waveform, spectrogram }

/// The shared audio view: either an envelope or a spectrogram, with the same selection
/// handle, region bars and playhead over both.
struct SampleScope: View {
    var mode: ScopeMode = .spectrogram
    let spectrum: [[Double]]
    var samples: [Float] = []
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double
    let regions: [VoiceRegion]
    let editable: Bool
    var corner: CGFloat = 0
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Surface.scope))
                switch mode {
                case .spectrogram: drawSpectrogram(&context, size)
                case .waveform: drawWaveform(&context, size)
                }
                guard duration > 0 else { return }
                drawSelection(&context, size)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .contentShape(RoundedRectangle(cornerRadius: corner))
            .gesture(editable ? DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard duration > 0, proxy.size.width > 0 else { return }
                    let second = max(0, min(duration, Double(value.location.x / proxy.size.width) * duration))
                    if dragStart == nil {
                        dragStart = max(0, min(duration, Double(value.startLocation.x / proxy.size.width) * duration))
                    }
                    start = min(dragStart ?? second, second)
                    end = max(dragStart ?? second, second)
                }
                .onEnded { _ in dragStart = nil } : nil)
        }
        .accessibilityLabel(mode == .waveform ? "Voice sample waveform" : "Voice sample spectrogram")
    }

    private func drawSpectrogram(_ context: inout GraphicsContext, _ size: CGSize) {
        guard !spectrum.isEmpty else { return }
        let cellWidth = size.width / CGFloat(spectrum.count)
        let binCount = spectrum.map(\.count).max() ?? 0
        guard binCount > 0 else { return }
        let cellHeight = size.height / CGFloat(binCount)
        for (columnIndex, column) in spectrum.enumerated() {
            for (binIndex, value) in column.enumerated() where value > 0.04 {
                let rect = CGRect(x: CGFloat(columnIndex) * cellWidth,
                                  y: size.height - CGFloat(binIndex + 1) * cellHeight,
                                  width: cellWidth + 0.5, height: cellHeight + 0.5)
                context.fill(Path(rect), with: .color(heat(max(0, min(1, value)))))
            }
        }
    }

    /// Purple through magenta to a hot yellow: the loud parts have to separate from the
    /// quiet ones at a glance.
    private func heat(_ value: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.07, 0.02, 0.16)),
            (0.35, (0.42, 0.06, 0.55)),
            (0.60, (0.85, 0.13, 0.45)),
            (0.80, (0.98, 0.45, 0.18)),
            (1.00, (1.00, 0.85, 0.42)),
        ]
        for index in 1..<stops.count where value <= stops[index].0 {
            let (lowPoint, low) = stops[index - 1]
            let (highPoint, high) = stops[index]
            let step = (value - lowPoint) / max(0.0001, highPoint - lowPoint)
            return Color(red: low.0 + (high.0 - low.0) * step,
                         green: low.1 + (high.1 - low.1) * step,
                         blue: low.2 + (high.2 - low.2) * step)
        }
        return Color(red: stops.last!.1.0, green: stops.last!.1.1, blue: stops.last!.1.2)
    }

    private func drawWaveform(_ context: inout GraphicsContext, _ size: CGSize) {
        let middle = size.height / 2
        context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
                     with: .color(Ink.faint.opacity(0.22)))
        guard !samples.isEmpty else { return }
        let columns = max(1, Int(size.width / 2))
        let perColumn = max(1, samples.count / columns)
        // Sampling every value of a long recording would cost more than it shows.
        let step = max(1, perColumn / 6)
        for column in 0..<columns {
            let begin = column * perColumn
            guard begin < samples.count else { break }
            let finish = min(samples.count, begin + perColumn)
            var peak: Float = 0
            var index = begin
            while index < finish {
                peak = max(peak, abs(samples[index]))
                index += step
            }
            let height = max(1, CGFloat(peak) * size.height * 0.92)
            let x = CGFloat(column) * size.width / CGFloat(columns)
            context.fill(Path(CGRect(x: x, y: middle - height / 2, width: 1.4, height: height)),
                         with: .color(Signal.selection.opacity(0.9)))
        }
    }

    private func drawSelection(_ context: inout GraphicsContext, _ size: CGSize) {
        let startX = CGFloat(max(0, min(duration, start)) / duration) * size.width
        let endX = CGFloat(max(0, min(duration, end)) / duration) * size.width
        context.fill(Path(CGRect(x: 0, y: 0, width: startX, height: size.height)),
                     with: .color(.black.opacity(0.6)))
        context.fill(Path(CGRect(x: endX, y: 0, width: max(0, size.width - endX), height: size.height)),
                     with: .color(.black.opacity(0.6)))
        context.stroke(Path(CGRect(x: startX, y: 1, width: max(1, endX - startX), height: size.height - 2)),
                       with: .color(Ink.strong), lineWidth: 1.5)

        for region in regions {
            let x = CGFloat(max(0, region.start) / duration) * size.width
            let width = CGFloat(max(0, region.end - region.start) / duration) * size.width
            context.fill(Path(roundedRect: CGRect(x: x, y: size.height - 8, width: max(1, width), height: 4),
                              cornerRadius: 2),
                         with: .color(speakerTint(region.speaker)))
        }

        let playheadX = CGFloat(max(0, min(duration, playhead)) / duration) * size.width
        var line = Path()
        line.move(to: CGPoint(x: playheadX, y: 0))
        line.addLine(to: CGPoint(x: playheadX, y: size.height))
        context.stroke(line, with: .color(Signal.live), lineWidth: 2)

        let leading = context.resolve(Text("0:00").font(TypeScale.helper))
        let trailing = context.resolve(Text(clockText(duration)).font(TypeScale.helper))
        context.draw(leading, at: CGPoint(x: 8, y: size.height - 14), anchor: .leading)
        context.draw(trailing, at: CGPoint(x: size.width - 8, y: size.height - 14), anchor: .trailing)
    }
}
