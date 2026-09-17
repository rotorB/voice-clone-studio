import AppKit
import SwiftUI

// The menu bar panel. Everything here is one tap from the top of the screen: start or
// stop live, capture a reference, speak a line, switch voice or template. Anything that
// needs a canvas — trimming a sample, reading the phrase log — lives in the studio window.
//
// The panel is a single column of full-width bands, the way a settings list is: a header
// strip names each section, a hairline closes it, and every row inside shares one left
// edge. Cards inside a 440pt popover only added borders to look past.

struct QuickPanelView: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingVoiceLibrary = false
    @State private var showingDiagnostics = false

    static let width: CGFloat = 440
    // A menu bar panel is a glance, not a window: it ends well above the bottom of a
    // laptop screen and scrolls for the rest.
    static let height: CGFloat = 596

    var body: some View {
        VStack(spacing: 0) {
            header
            PanelHairline()
            ScrollView {
                VStack(spacing: 0) {
                    transportBand
                    meterBand
                    sampleSection
                    speechSection
                    composeSection
                    if !model.tracks.isEmpty { takesSection }
                }
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Surface.canvas)
        .foregroundStyle(Ink.body)
        .tint(Signal.primary)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingVoiceLibrary) { VoiceLibraryEditor().environmentObject(model) }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform.path")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Signal.primary)
            Text("Voice Studio").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.strong)
            Spacer(minLength: 8)
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
            .help("Switch the voice this panel speaks in")

            Button { openStudio() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(IconButtonStyle()).help("Open the full studio")
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
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Surface.plateHeader)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            EngineLights(backend: model.backend)
            Spacer(minLength: 8)
            Text(model.referenceReady ? "Voice ready" : "No voice yet")
                .font(TypeScale.helper)
                .foregroundStyle(model.referenceReady ? Signal.ready : Signal.warn)
            Text("v0.9").font(TypeScale.helper).foregroundStyle(Ink.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Surface.plateHeader)
        .overlay(alignment: .top) { PanelHairline() }
    }

    // MARK: - Transport

    /// The two things the panel exists for, above everything else: speak live, or capture
    /// a reference.
    private var transportBand: some View {
        HStack(spacing: 8) {
            TransportButton(title: model.isLive ? "Stop live" : "Start live",
                            detail: liveDetail,
                            icon: model.isLive ? "stop.fill" : "waveform.badge.mic",
                            fill: model.isLive ? Signal.liveFill : Signal.primaryFill,
                            enabled: model.referenceReady || model.isLive) {
                Task { await model.toggleLive() }
            }
            TransportButton(title: model.isRecording ? "Stop" : "Record",
                            detail: model.isRecording ? clockText(model.duration) : "\(Int(model.recordingBufferSeconds)) s buffer",
                            icon: model.isRecording ? "stop.fill" : "record.circle",
                            fill: model.isRecording ? Signal.liveFill : nil,
                            outline: Signal.live,
                            enabled: !model.isWorking && !model.isLive) {
                if model.isRecording { model.stopRecording() } else { Task { await model.startRecording() } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// What the microphone is actually hearing, for both live and capture.
    private var meterBand: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                StateDot(color: meterTint, size: 6)
                Text(meterCaption).font(TypeScale.meta).foregroundStyle(meterTint)
                Spacer(minLength: 8)
                Text(clockText(model.duration)).font(.system(size: 13, weight: .semibold))
                    .monospacedDigit().foregroundStyle(Ink.strong)
                Text(decibelText(model.isLive ? model.liveInputLevel : model.sampleInputLevel))
                    .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.soft)
                    .frame(width: 52, alignment: .trailing)
            }
            LevelHistory(values: model.isLive ? model.liveLevels : model.sampleLevels,
                         active: model.isRecording || model.isLive)
                .frame(height: 30)
            InputLevelBar(level: model.isLive ? model.liveInputLevel : model.sampleInputLevel)
                .frame(height: 5)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    // MARK: - Sections

    private var sampleSection: some View {
        PanelSection("Reference sample", note: sampleNote) {
            PanelRow("Source") {
                HStack(spacing: 6) {
                    ChoiceChip(title: "Microphone", icon: "mic",
                               selected: model.captureSource != .system) { model.captureSource = .microphone }
                    ChoiceChip(title: "System audio", icon: "display",
                               selected: model.captureSource == .system) { model.captureSource = .system }
                }
                .frame(width: 250)
                .disabled(model.isRecording || model.isLive)
            }
            PanelHairline().opacity(0.6)
            PanelRow("Microphone") {
                Menu {
                    ForEach(model.inputDevices) { device in
                        Button(device.name) { model.selectInput(device.id) }
                    }
                    Divider()
                    Button("Refresh microphones") { model.refreshInputs() }
                } label: {
                    MenuChip(title: selectedInputName, icon: "mic", fills: true)
                }
                .studioMenu().frame(width: 250)
                .disabled(model.captureSource == .system || model.isRecording || model.isLive)
            }
            PanelHairline().opacity(0.6)
            PanelRow("Keep") {
                HStack(spacing: 6) {
                    Menu {
                        ForEach([10, 20, 30, 60], id: \.self) { value in
                            Button("The last \(value) seconds") { model.recordingBufferSeconds = Double(value) }
                        }
                    } label: { MenuChip(title: "Last \(Int(model.recordingBufferSeconds)) s", fills: true) }
                        .studioMenu()
                        .disabled(model.isRecording)
                    Button { chooseAudioSample(into: model) } label: {
                        Label("Load a file", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isRecording || model.isLive)
                }
                .frame(width: 250)
            }
            if model.duration > 0 && !model.isRecording {
                PanelHairline().opacity(0.6)
                // The actions need the full width, so this row drops the label column.
                HStack(spacing: 7) {
                    Text(sampleHeadline).font(TypeScale.helper).monospacedDigit()
                        .foregroundStyle(Ink.soft).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { model.playSelection() } label: {
                        Label(model.isAuditioning ? "Stop" : "Listen",
                              systemImage: model.isAuditioning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.isLive)
                    Button("Trim") { openStudio() }.buttonStyle(SecondaryButtonStyle())
                    Button(model.isWorking ? "Preparing…" : "Use as voice") {
                        Task { await model.useWholeRecording() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isWorking || model.isLive)
                }
                .padding(.horizontal, 14).frame(height: 44)
            }
        }
    }

    private var speechSection: some View {
        PanelSection("Speech") {
            PanelRow("Translate") {
                HStack(spacing: 6) {
                    Toggle("", isOn: $model.translatorEnabled)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    Spacer(minLength: 6)
                    if model.translatorEnabled {
                        languageMenu($model.translationSource)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Ink.faint)
                        languageMenu($model.translationTarget)
                    } else {
                        languageMenu($model.recognitionLanguage)
                    }
                }
                .frame(width: 250)
                .disabled(model.isLive)
            }
            PanelHairline().opacity(0.6)
            PanelRow("Catch up") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $model.automaticTempo)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    Text(model.automaticTempo ? "Automatic" : "Fixed tempo")
                        .font(TypeScale.helper).foregroundStyle(Ink.soft)
                    Spacer(minLength: 6)
                    Text(String(format: "%.2f×", model.actualTempo))
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Signal.primary)
                }.frame(width: 250)
            }
            PanelHairline().opacity(0.6)
            PanelRow("Speed") {
                Slider(value: $model.liveTempo, in: 0.8...1.5).controlSize(.small)
                    .accessibilityLabel("Base speech tempo")
                    .frame(width: 250)
            }
        }
    }

    private var composeSection: some View {
        PanelSection("Say something", trailing: "\(model.typedText.count) / 2000") {
            TextEditor(text: $model.typedText)
                .font(.system(size: 13)).foregroundStyle(Ink.strong)
                .scrollContentBackground(.hidden)
                .frame(height: 58)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Surface.sunken)
                .overlay(alignment: .topLeading) {
                    if model.typedText.isEmpty {
                        Text("Type a line, or pick a template.")
                            .font(.system(size: 13)).foregroundStyle(Ink.faint)
                            .padding(.horizontal, 14).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) { PanelHairline().opacity(0.6) }
                .onChange(of: model.typedText) { _, text in
                    if text.count > 2000 { model.typedText = String(text.prefix(2000)) }
                }
            HStack(spacing: 8) {
                templatesMenu
                Button("Clear") { model.typedText = "" }
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.typedText.isEmpty)
                Spacer(minLength: 8)
                Button { Task { await model.generateText() } } label: {
                    Label(model.isWorking ? "Generating…" : "Generate", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.referenceReady || model.isWorking || trimmedText.isEmpty)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
        }
    }

    private var takesSection: some View {
        PanelSection("Recent takes", trailing: "\(model.tracks.count) total") {
            ForEach(Array(model.tracks.suffix(3).reversed())) { track in
                HStack(spacing: 10) {
                    Button { Task { await model.play(track) } } label: {
                        Image(systemName: model.playingTrack == track.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(model.playingTrack == track.id ? "Stop" : "Play this take")
                    Text(track.text).font(TypeScale.helper).foregroundStyle(Ink.body).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f s", track.audio.duration))
                        .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.faint)
                    Button { model.reveal(track) } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).foregroundStyle(Ink.faint).help("Show in Finder")
                }
                .padding(.horizontal, 14).frame(height: 36)
                if track.id != model.tracks.suffix(3).first?.id { PanelHairline().opacity(0.6) }
            }
        }
    }

    // MARK: - Bits

    private var templatesMenu: some View {
        Menu {
            if model.textTemplates.isEmpty {
                Text("No templates saved yet")
            } else {
                ForEach(model.textTemplates, id: \.self) { template in
                    Button(shortened(template)) { model.typedText = template }
                }
                Divider()
                Menu("Remove a template") {
                    ForEach(model.textTemplates, id: \.self) { template in
                        Button(shortened(template)) { model.removeTextTemplate(template) }
                    }
                }
            }
            Divider()
            Button("Save this text as a template") { model.saveTextTemplate(model.typedText) }
                .disabled(trimmedText.isEmpty)
        } label: {
            MenuChip(title: "Templates", icon: "text.badge.plus")
        }
        .studioMenu().fixedSize()
    }

    private func languageMenu(_ value: Binding<String>) -> some View {
        Menu {
            ForEach(liveLanguages, id: \.self) { language in
                Button(language) { value.wrappedValue = language }
            }
        } label: { MenuChip(title: value.wrappedValue, fills: true) }
            .studioMenu()
    }

    /// LSUIElement apps do not front their own windows.
    private func openStudio() {
        openWindow(id: "studio")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func shortened(_ text: String) -> String {
        text.count <= 44 ? text : String(text.prefix(43)) + "…"
    }

    private var trimmedText: String { model.typedText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var activeVoiceName: String {
        model.savedVoices.first(where: { $0.id == model.activeVoiceID })?.name
        ?? (model.referenceReady ? "Reference ready" : "No voice yet")
    }

    private var selectedInputName: String {
        model.captureSource == .system ? "System audio"
        : model.inputDevices.first(where: { $0.id == model.selectedInput })?.name ?? "Microphone"
    }

    private var sampleNote: String? {
        model.duration > 0 && !model.isRecording ? model.sampleStatus : nil
    }

    /// Kept short: the selection and the engine's own words are on the section header line.
    private var sampleHeadline: String {
        String(format: "%.1f s · %d kHz", model.duration, Int(model.sampleRate / 1000))
    }

    private var liveDetail: String {
        if model.liveState == "ERROR" { return "Error" }
        if model.isLive { return model.telemetry.generationLagSeconds > 5 ? "catching up" : "listening" }
        return model.referenceReady ? "ready" : "needs a voice"
    }

    private var meterCaption: String {
        if model.isRecording { return "Recording" }
        if model.isLive { return model.liveInputLevel > 0.04 ? "Live — signal" : "Live — quiet" }
        if model.duration > 0 { return "Captured" }
        return "Standby"
    }

    private var meterTint: Color {
        if model.isRecording { return Signal.live }
        if model.isLive { return Signal.primary }
        return Ink.soft
    }
}

// MARK: - Panel chrome

struct PanelHairline: View {
    var body: some View { Rectangle().fill(Surface.rule).frame(height: 1) }
}

/// A full-width band: a named header strip, then rows that share one left edge. Flat on
/// purpose — in a 440pt popover a card inside a card is two borders and no information.
struct PanelSection<Content: View>: View {
    let title: String
    var trailing: String?
    var note: String?
    @ViewBuilder let content: Content

    init(_ title: String, trailing: String? = nil, note: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHairline()
            HStack(spacing: 8) {
                Text(title).font(TypeScale.section).foregroundStyle(Ink.strong)
                if let note {
                    Text(note).font(TypeScale.helper).foregroundStyle(Ink.soft).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.faint)
                }
            }
            .padding(.horizontal, 14).frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.plateHeader)
            PanelHairline()
            VStack(spacing: 0) { content }
        }
    }
}

/// Label on the left, control on the right, one height for every row in the panel.
struct PanelRow<Control: View>: View {
    let label: String
    var dense = false
    @ViewBuilder let control: Control

    init(_ label: String, dense: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.dense = dense
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(dense ? TypeScale.helper : TypeScale.label)
                .foregroundStyle(dense ? Ink.soft : Ink.body)
                .monospacedDigit().lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14).frame(height: 36)
    }
}

/// The panel's primary actions: wide, flat, readable at a glance.
struct TransportButton: View {
    let title: String
    let detail: String
    let icon: String
    /// Filled when this is the action to take; outlined otherwise.
    var fill: Color?
    var outline: Color = Signal.primary
    var enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(TypeScale.helper).opacity(0.78)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(fill == nil ? outline : Ink.onPrimary)
            .padding(.horizontal, 12).frame(height: 44).frame(maxWidth: .infinity)
            .background(fill ?? Surface.control, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(fill == nil ? outline.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
