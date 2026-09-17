import SwiftUI

// A neutral instrument console: every surface is a true grey (R = G = B), so nothing in
// the chrome reads as brown or as blue. Colour appears only where it means something —
// azure for anything you can act on, amber for signal travelling between stages.
// Every token below exists so that no view invents a size or a grey.

extension Color {
    init(_ hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Text tones. `soft` is the floor for anything a person has to read; `faint` is only for
/// text that repeats information already carried by position or colour.
enum Ink {
    static let strong = Color(0xF2F2F2)
    static let body = Color(0xD2D2D2)
    static let soft = Color(0xA4A4A4)
    /// Still above 4.5:1 on a plate — nothing in this interface goes dimmer than this.
    static let faint = Color(0x8B8B8B)
    static let onScope = Color(0xF2F2F2)
    static let onScopeSoft = Color(0xA4A4A4)
    /// Text on a filled accent button. The fills are deep enough to carry white.
    static let onPrimary = Color(0xFFFFFF)
}

enum Surface {
    static let canvas = Color(0x191919)
    static let plate = Color(0x303030)
    static let plateHeader = Color(0x262626)
    /// Wells: text fields, meters, lists. Recessed, so darker than the plate.
    static let sunken = Color(0x1B1B1B)
    /// Anything you can press. Raised, so lighter than the plate — a control that is
    /// darker than what it sits on cannot be seen at all.
    static let control = Color(0x414141)
    static let controlActive = Color(0x4E4E4E)
    static let rule = Color(0x434343)
    static let ruleStrong = Color(0x5C5C5C)
    static let scope = Color(0x131313)
}

/// Azure for anything you can act on — it is the only colour on the chrome, so a control is
/// found by hue alone. Amber stays on the graph links, where it marks the signal itself.
enum Signal {
    static let primary = Color(0x2BA6E0)
    static let primaryDim = Color(0x1B87BC)
    /// The same azure taken deep enough that white sits on it at 4.5:1. Bright accents are
    /// for strokes and text on dark; a filled button uses these.
    static let primaryFill = Color(0x1A7EB2)
    static let live = Color(0xE05A46)
    static let liveFill = Color(0xC4432F)
    static let ready = Color(0x7FC75C)
    static let warn = Color(0xE8B33C)
    /// Reads brightly against the scope background.
    static let selection = Color(0x4FC3F7)
}

/// Tokens that only the graph workspace uses.
enum Graph {
    /// Links are drawn as a gradient from the stage that produces the voice model to the
    /// stage that consumes it, so a glance says which way the signal travels.
    static let edgeFrom = Color(0xF2B846)
    static let edgeTo = Color(0xE0723A)
    static let edge = Color(0xE89141)
    static let gridMinor = Color(0x1F1F1F)
    static let gridMajor = Color(0x282828)
    static let nodeMark = Color(0xE8B33C)
}

enum TypeScale {
    static let readout = Font.system(size: 34, weight: .semibold, design: .rounded)
    static let readoutSmall = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 17, weight: .semibold)
    static let section = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)
    static let value = Font.system(size: 12, weight: .semibold)
    static let helper = Font.system(size: 11)
    static let meta = Font.system(size: 11, weight: .medium)
}

func speakerTint(_ index: Int?) -> Color {
    switch index {
    case 0: return Color(0x4FC3F7)
    case 1: return Color(0x5FD0A8)
    case 2: return Color(0xE8A24D)
    case 3: return Color(0xC79BE8)
    default: return Color(0x767676)
    }
}

// MARK: - Primitives

/// A single instrument faceplate. Content inside is separated by `PlateRule`, not by
/// nesting more cards.
struct Faceplate<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Surface.plate, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Surface.rule))
    }
}

struct PlateRule: View {
    var body: some View { Rectangle().fill(Surface.rule).frame(height: 1) }
}

/// Section heading inside a faceplate. Sentence case, full contrast — the label is part of
/// the content, not a decorative eyebrow.
struct SectionHeading: View {
    let text: String
    var trailing: AnyView?

    init(_ text: String) { self.text = text; self.trailing = nil }
    init<T: View>(_ text: String, @ViewBuilder trailing: () -> T) {
        self.text = text
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(TypeScale.section).foregroundStyle(Ink.strong)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
    }
}

/// Label on the left, control on the right. Every setting in the studio uses this, so the
/// right-hand column can be scanned in one pass.
struct FieldRow<Control: View>: View {
    let label: String
    /// Rendered on its own line under the row: a narrow strip has no room for a second
    /// column of prose next to the control.
    var note: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label).font(TypeScale.label).foregroundStyle(Ink.body).lineLimit(1)
                Spacer(minLength: 8)
                control.layoutPriority(1)
            }
            if let note {
                Text(note).font(TypeScale.helper).foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The one loud element in the studio: a measured number.
struct Readout: View {
    let value: String
    let unit: String
    let caption: String
    var tint: Color = Ink.strong
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(compact ? TypeScale.readoutSmall : TypeScale.readout)
                    .monospacedDigit().foregroundStyle(tint)
                Text(unit).font(TypeScale.meta).foregroundStyle(Ink.soft)
            }
            Text(caption).font(TypeScale.helper).foregroundStyle(Ink.soft).lineLimit(1)
        }
    }
}

struct StateDot: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.10)))
    }
}

struct StatusLine: View {
    let text: String
    let ready: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            StateDot(color: ready ? Signal.ready : Signal.warn, size: 6).padding(.top, 4)
            Text(text).font(TypeScale.helper).foregroundStyle(Ink.soft)
                .fixedSize(horizontal: false, vertical: true).lineLimit(3).help(text)
        }
    }
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            StateDot(color: color, size: 6)
            Text(title).font(TypeScale.meta).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.22)))
    }
}

// MARK: - Controls

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = Signal.primaryFill
    var foreground: Color = Ink.onPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14).frame(height: 32)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.30)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Ink.body)
            .padding(.horizontal, 12).frame(height: 28)
            .background(configuration.isPressed ? Surface.controlActive : Surface.control, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Surface.ruleStrong))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.label)
            .foregroundStyle(Signal.primary.opacity(configuration.isPressed ? 0.6 : 1))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Ink.body)
            .frame(width: 30, height: 28)
            .background(configuration.isPressed ? Surface.controlActive : Surface.control, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Surface.ruleStrong))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Native pop-up buttons draw their own chrome and paint the label with the system control
/// colour, which lands as near-black on these surfaces. Every menu in the studio uses one
/// of these labels instead, so the text colour is ours; `MenuChipStyle` draws the chrome.
struct MenuChip: View {
    let title: String
    var icon: String?
    var fills = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Ink.soft)
            }
            Text(title).font(TypeScale.label).foregroundStyle(Ink.strong).lineLimit(1)
            if fills { Spacer(minLength: 4) }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                .foregroundStyle(Ink.soft)
        }
        .frame(maxWidth: fills ? .infinity : nil)
    }
}

struct MenuIconChip: View {
    let icon: String

    var body: some View {
        Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Ink.body)
            .frame(width: 12)
    }
}

/// The chrome behind a menu label: raised, outlined, and pressed-state aware.
struct MenuChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 9).frame(height: 28)
            .background(configuration.isPressed ? Surface.controlActive : Surface.control,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Surface.ruleStrong))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
    }
}

extension View {
    /// A text field that stays legible: the system's own styling paints dark text here.
    func studioField() -> some View {
        textFieldStyle(.plain)
            .font(TypeScale.body)
            .foregroundStyle(Ink.strong)
            .padding(.horizontal, 8).frame(height: 26)
            .background(Surface.sunken, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Surface.ruleStrong))
    }

    /// Menus are ours, not AppKit's: `.button` lets a ButtonStyle paint the control, so the
    /// label keeps our ink instead of the system's near-black control colour.
    func studioMenu() -> some View {
        menuStyle(.button).buttonStyle(MenuChipStyle()).menuIndicator(.hidden)
    }
}
