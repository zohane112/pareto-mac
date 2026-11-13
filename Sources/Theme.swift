// The look, shared with the Chrome extension. Two of them, picked in settings:
//   digital   the default: a light grey panel with black type, like an inverted terminal.
//             The selected row and the answer turn black. Seven-segment type (DSEG7) for the
//             wordmark and big numbers, like a clock, Geist Mono for what you scan, Geist for
//             what you read. One amber light, only for the mark, listening, and what needs you.
//   terminal  plain: black, grey monospace, no glow.

import AppKit
import CoreText
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum Look: String, CaseIterable, Identifiable {
    case digital, terminal
    var id: String { rawValue }
}

/// The typefaces in the app's Resources/Fonts, registered for this process at launch. All of them
/// are under the SIL Open Font License; the licences sit beside them.
enum Fonts {
    static func register() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

enum Theme {
    static var look: Look { Settings.shared.look }
    static var digital: Bool { look == .digital }

    // Surfaces
    static var panel: Color { digital ? Color(hex: 0xF6F6F3) : Color(hex: 0x0E0E0E) }
    /// The track behind a switch, and the settings header.
    static var well: Color { digital ? Color(hex: 0xE6E6E1) : Color(hex: 0x1A1A19) }
    static var band: Color { digital ? Color(hex: 0xEFEFEB) : Color(hex: 0x121211) }
    /// The desktop-grey ground of the PDF viewer.
    static var ground: Color { digital ? Color(hex: 0xE9E9E5) : Color(hex: 0x0A0A0A) }

    // Type
    static var ink: Color { digital ? Color(hex: 0x0C0C0C) : Color(hex: 0xE8E8E3) }
    static var soft: Color { digital ? Color(hex: 0x3A3A36) : Color(hex: 0xBDBDB7) }
    static var mute: Color { digital ? Color(hex: 0x62625D) : Color(hex: 0x8C8C86) }

    // Lines
    static var hairline: Color { digital ? Color(hex: 0xCFCFC9) : Color(hex: 0x2E2E2B) }
    static var rule: Color { digital ? Color(hex: 0xE1E1DC) : Color(hex: 0x2E2E2B) }

    /// Inverted: the selected row, the answer, a primary button.
    static var invert: Color { ink }
    static var onInvert: Color { panel }
    static var muteOnInvert: Color { digital ? Color(hex: 0xA9A9A3) : Color(hex: 0x55554F) }

    /// The one colour, amber: the mark's light, listening, and "not allowed yet". Only ever a
    /// light or a fill, never text: it's too pale to read on the light panel.
    static let signal = Color(hex: 0xF5A000)
    /// The faint unlit segments behind the wordmark, like a clock's "888".
    static var ghost: Color { digital ? Color(hex: 0xD8D8D2) : Color(hex: 0x2A2A27) }

    static var radius: CGFloat { digital ? 20 : 10 }
    static let line: CGFloat = 1
    /// Every size in the views is multiplied by this, so the whole bar can be resized in one place.
    static let scale: CGFloat = 0.85

    static var nsInk: NSColor { digital ? NSColor(hex: 0x0C0C0C) : NSColor(hex: 0xE8E8E3) }
    static var nsMute: NSColor { digital ? NSColor(hex: 0x62625D) : NSColor(hex: 0x8C8C86) }
    static var appearance: NSAppearance? { NSAppearance(named: digital ? .aqua : .darkAqua) }

    private static func heavy(_ weight: Font.Weight) -> Bool {
        weight == .medium || weight == .semibold || weight == .bold || weight == .heavy || weight == .black
    }

    /// Geist Mono: the prompt, labels, results, status.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(heavy(weight) ? "GeistMono-Medium" : "GeistMono-Regular", size: size * scale)
    }
    /// Geist: answers and explanations, the things you read. The terminal look reads in mono too.
    static func read(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard digital else { return mono(size, weight) }
        let name = weight == .semibold || weight == .bold ? "Geist-SemiBold" : heavy(weight) ? "Geist-Medium" : "Geist-Regular"
        return .custom(name, size: size * scale)
    }
    /// DSEG7, the seven-segment face: the wordmark and big numbers. It has digits, letters and
    /// a few marks but no "%", so a "%" beside it is set in mono. Plain mono in the terminal look.
    static func display(_ size: CGFloat) -> Font {
        digital ? .custom("DSEG7Classic-Bold", size: size * scale) : mono(size * 0.8, .medium)
    }
    static func nsMono(_ size: CGFloat) -> NSFont {
        NSFont(name: "GeistMono-Regular", size: size * scale) ?? .monospacedSystemFont(ofSize: size * scale, weight: .regular)
    }
    /// A small uppercase label, letter-spaced.
    static func label(_ text: String) -> some View {
        Text(digital ? text.uppercased() : "# " + text)
            .font(mono(10.5))
            .tracking(digital ? 1.2 : 0)
            .foregroundColor(mute)
    }
}

/// A window's frame: a solid panel, a hairline, and a soft shadow. No glass, no glow.
struct Panel<Content: View>: View {
    var cornerRadius: CGFloat = Theme.radius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: Theme.line)
            )
            .shadow(color: .black.opacity(Theme.digital ? 0.14 : 0.45), radius: Theme.digital ? 26 : 18, y: Theme.digital ? 14 : 8)
    }
}

/// The line between parts of a panel: dashed in the digital look, solid in the terminal.
struct Divider2: View {
    var dashed = true
    var body: some View {
        if dashed && Theme.digital {
            Rectangle().fill(.clear).frame(height: 1)
                .overlay(Line().stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        } else {
            Rectangle().fill(dashed ? Theme.hairline : Theme.rule).frame(height: 1)
        }
    }
    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: 0, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

/// A rounded button: filled black (primary) or outlined.
struct PillButton: View {
    var title: String
    var primary = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(12.5))
                .foregroundColor(primary ? Theme.onInvert : Theme.ink)
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(Capsule().fill(primary ? Theme.invert : .clear))
                .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(primary ? .clear : Theme.ink, lineWidth: Theme.line))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// A row of choices in a rounded track; the chosen one is inverted.
struct PillSwitch<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(Theme.mono(12.5))
                        .foregroundColor(selection == value ? Theme.onInvert : Theme.ink)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(Capsule().fill(selection == value ? Theme.invert : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.well))
        .fixedSize()
    }
}

/// How sure Jev is, as a row of segments like a level meter: lit ones in ink, the rest in the
/// hairline grey. Given the moment the answer arrived, it fills one segment at a time.
struct SegmentMeter: View {
    var value: Double
    var segments = 18
    var since: Date? = nil

    private var lit: Int { Int((max(0, min(1, value)) * Double(segments)).rounded()) }

    var body: some View {
        Group {
            if let since, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               Date().timeIntervalSince(since) < Self.fillTime {
                // One redraw per segment, then it stops.
                TimelineView(.explicit((0...segments).map { since.addingTimeInterval(Self.fillTime * Double($0) / Double(segments)) })) { context in
                    let shown = Int(context.date.timeIntervalSince(since) / Self.fillTime * Double(segments))
                    bars(min(lit, max(0, shown)))
                }
            } else {
                bars(lit)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int((value * 100).rounded()))% sure")
    }

    static let fillTime = 0.9

    private func bars(_ on: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < on ? (value < 0.5 ? Theme.mute : Theme.ink) : Theme.hairline)
                    .frame(width: 6, height: 9)
            }
        }
    }
}

/// Five short segments lighting in turn, for "working on it".
struct LoadingSegments: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = (t / 1.2 - Double(i) * 0.125).truncatingRemainder(dividingBy: 1)
                    let p = phase < 0 ? phase + 1 : phase
                    RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Theme.ink)
                        .frame(width: 10, height: 3.5)
                        .opacity(p < 0.4 ? 0.15 + p / 0.4 * 0.85 : max(0.15, 1 - (p - 0.4) / 0.6 * 0.85))
                }
            }
        }
        .accessibilityLabel("working")
    }
}

/// A small round status light: ink when on, amber when not yet allowed.
struct StatusDot: View {
    var on: Bool
    var body: some View {
        Circle().fill(on ? Theme.ink : Theme.signal).frame(width: 7, height: 7)
    }
}

/// The name, "Pareto", in seven-segment type over its faint unlit segments, with the amber
/// light. Plain mono in the terminal look.
struct Wordmark: View {
    var size: CGFloat
    var light = true

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.16) {
            if Theme.digital {
                ZStack(alignment: .leading) {
                    Text("888888").foregroundColor(Theme.ghost).accessibilityHidden(true)
                    Text("Pareto").foregroundColor(Theme.ink)
                }
                .font(Theme.display(size))
                if light {
                    Circle().fill(Theme.signal).frame(width: size * 0.19, height: size * 0.19)
                        .background(Circle().fill(Theme.signal.opacity(0.18)).padding(-size * 0.05))
                }
            } else {
                Text("pareto").font(Theme.mono(size * 0.52, .medium)).foregroundColor(Theme.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pareto")
    }
}

/// The app's mark: a seven-segment "P" on a pale tile, its unlit segments faint, and the
/// decimal point lit amber. The same mark is drawn into the app icon at build time.
struct AppMark: View {
    var tile = true

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            if tile {
                let tileRect = CGRect(x: 0, y: 0, width: s, height: s)
                let shape = Path(roundedRect: tileRect, cornerRadius: s * 0.225, style: .continuous)
                ctx.fill(shape, with: .color(Color(hex: 0xEDEDE9)))
                ctx.stroke(shape, with: .color(Color(hex: 0xCFCFC9)), lineWidth: max(1, s * 0.006))
            }
            // The digit cell: segments a (top), b, c (right), d (bottom), e, f (left), g (middle).
            let w = s * 0.40, h = s * 0.62, t = s * 0.085, gap = s * 0.012
            let x0 = (s - w) / 2 - s * 0.05, y0 = (s - h) / 2
            func horizontal(_ y: CGFloat) -> Path {
                let l = x0 + gap + t / 2, r = x0 + w - gap - t / 2
                return Path { p in
                    p.move(to: CGPoint(x: l, y: y)); p.addLine(to: CGPoint(x: l + t / 2, y: y - t / 2))
                    p.addLine(to: CGPoint(x: r - t / 2, y: y - t / 2)); p.addLine(to: CGPoint(x: r, y: y))
                    p.addLine(to: CGPoint(x: r - t / 2, y: y + t / 2)); p.addLine(to: CGPoint(x: l + t / 2, y: y + t / 2))
                    p.closeSubpath()
                }
            }
            func vertical(_ x: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Path {
                let a = top + gap + t / 2, b = bottom - gap - t / 2
                return Path { p in
                    p.move(to: CGPoint(x: x, y: a)); p.addLine(to: CGPoint(x: x + t / 2, y: a + t / 2))
                    p.addLine(to: CGPoint(x: x + t / 2, y: b - t / 2)); p.addLine(to: CGPoint(x: x, y: b))
                    p.addLine(to: CGPoint(x: x - t / 2, y: b - t / 2)); p.addLine(to: CGPoint(x: x - t / 2, y: a + t / 2))
                    p.closeSubpath()
                }
            }
            let top = y0 + t / 2, mid = y0 + h / 2, bottom = y0 + h - t / 2
            let left = x0 + t / 2, right = x0 + w - t / 2
            let segments: [(Path, Bool)] = [
                (horizontal(top), true),                 // a
                (vertical(right, top, mid), true),       // b
                (vertical(right, mid, bottom), false),   // c
                (horizontal(bottom), false),             // d
                (vertical(left, mid, bottom), true),     // e
                (vertical(left, top, mid), true),        // f
                (horizontal(mid), true),                 // g
            ]
            for (path, lit) in segments {
                ctx.fill(path, with: .color(lit ? Color(hex: 0x0C0C0C) : Color(hex: 0xD8D8D2)))
            }
            // The decimal point, lit amber, with a soft halo.
            let r = t * 0.62
            let point = CGPoint(x: x0 + w + t * 0.9, y: bottom + t * 0.05)
            ctx.fill(Path(ellipseIn: CGRect(x: point.x - r * 1.7, y: point.y - r * 1.7, width: r * 3.4, height: r * 3.4)),
                     with: .color(Color(hex: 0xF5A000, opacity: 0.18)))
            ctx.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                     with: .color(Color(hex: 0xF5A000)))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
