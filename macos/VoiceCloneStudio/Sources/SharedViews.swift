import AppKit
import SwiftUI

// Views used by both surfaces: the menu bar panel and the studio window.

struct PageHeader: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) { self.title = title; self.detail = detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(TypeScale.title).foregroundStyle(Ink.strong)
            Text(detail).font(TypeScale.helper).foregroundStyle(Ink.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Mirrored bars around a centre line: a level history that reads like a waveform.
struct LevelHistory: View {
    let values: [Double]
    let active: Bool
    private let slots = 100

    var body: some View {
        Canvas { context, size in
            let slot = size.width / CGFloat(slots)
            let barWidth = max(1.5, slot * 0.5)
            let middle = size.height / 2
            context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
                         with: .color(Ink.faint.opacity(0.22)))
            for index in 0..<slots {
                let offset = index - (slots - values.count)
                let value = offset >= 0 && offset < values.count ? values[offset] : 0
                let height = max(2, value * size.height * 0.94)
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                let rect = CGRect(x: x, y: middle - height / 2, width: barWidth, height: height)
                let tint = active ? Signal.selection.opacity(max(0.35, min(1, 0.4 + value)))
                                  : Ink.faint.opacity(0.32)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
            }
        }.accessibilityLabel("Recent input level history")
    }
}

struct InputLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Surface.sunken)
                    .overlay(Capsule().strokeBorder(Surface.rule))
                Capsule().fill(level > 0.94 ? Signal.live : Signal.ready)
                    .frame(width: proxy.size.width * max(0, min(1, level)))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Input level").accessibilityValue("\(Int(level * 100)) percent")
    }
}

struct EngineLights: View {
    @ObservedObject var backend: BackendService

    var body: some View {
        HStack(spacing: 12) {
            light("Engine", backend.isOnline ? "ready" : "offline")
            light("Recognition", backend.healthSnapshot?.asrState ?? "unloaded")
            light("Voice", backend.healthSnapshot?.ttsState ?? "unloaded")
        }
    }

    private func light(_ text: String, _ state: String) -> some View {
        HStack(spacing: 5) {
            StateDot(color: tint(state), size: 6)
            Text(text).font(TypeScale.helper).foregroundStyle(Ink.soft)
        }.help("\(text): \(state)")
    }

    private func tint(_ state: String) -> Color {
        switch state {
        case "ready": return Signal.ready
        case "working": return Signal.warn
        case "offline": return Signal.live
        default: return Surface.ruleStrong
        }
    }
}

struct VoiceLibraryEditor: View {
    @EnvironmentObject private var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var voiceToDelete: SavedVoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PageHeader("Voice library", detail: "Switch to a saved voice, or remove one you no longer need.")
                Spacer(minLength: 10)
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
            }

            if model.savedVoices.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.wave.2").font(.system(size: 24, weight: .light))
                        .foregroundStyle(Signal.primary.opacity(0.6))
                    Text("No saved voices yet").font(TypeScale.body).foregroundStyle(Ink.body)
                    Text("Capture a reference, name it, and save.")
                        .font(TypeScale.helper).foregroundStyle(Ink.soft)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.savedVoices) { voice in
                            HStack(spacing: 10) {
                                Image(systemName: model.activeVoiceID == voice.id ? "checkmark.circle.fill" : "person.wave.2")
                                    .font(.system(size: 14))
                                    .foregroundStyle(model.activeVoiceID == voice.id ? Signal.ready : Ink.faint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name).font(TypeScale.value).foregroundStyle(Ink.strong)
                                    Text(String(format: "%.1f s reference in %@", voice.seconds, voice.language ?? "Auto"))
                                        .font(TypeScale.helper).monospacedDigit().foregroundStyle(Ink.soft)
                                }
                                Spacer(minLength: 10)
                                Button("Use") { Task { await model.activateSavedVoice(voice) } }
                                    .buttonStyle(QuietButtonStyle())
                                    .disabled(model.activeVoiceID == voice.id)
                                Button { voiceToDelete = voice } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(Ink.faint).help("Delete \(voice.name)")
                            }.padding(.vertical, 9)
                            if voice.id != model.savedVoices.last?.id { PlateRule() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .background(Surface.plate, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Surface.rule))
            }
        }
        .padding(18)
        .frame(width: 460, height: 380)
        .background(Surface.canvas)
        .foregroundStyle(Ink.body)
        .tint(Signal.primary)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Delete this saved voice?",
            isPresented: Binding(
                get: { voiceToDelete != nil },
                set: { if !$0 { voiceToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete \(voiceToDelete?.name ?? "voice")", role: .destructive) {
                guard let voice = voiceToDelete else { return }
                voiceToDelete = nil
                Task { await model.deleteSavedVoice(voice) }
            }
            Button("Cancel", role: .cancel) { voiceToDelete = nil }
        } message: {
            Text("The profile is removed from the library. Audio already generated stays on disk.")
        }
    }
}
