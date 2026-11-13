// Settings, which also greets new users: the shortcut, the plan, the Jev and Nebius keys,
// reading the screen, the look, voice, and starting at login. Numbered in the order a new user
// sets them.

import AppKit
import Combine
import SwiftUI

/// The settings window's own state: what's typed in the key field, the last message, and
/// whether reading the screen is allowed yet (checked every second and a half).
final class SettingsState: ObservableObject {
    @Published var keyInput = ""
    @Published var keyMessage = ""
    @Published var nebiusInput = ""
    @Published var nebiusMessage = ""
    @Published var trusted = WindowReader.trusted
    @Published var screenAllowed = ScreenShot.allowed
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var state: SettingsState
    var welcome = false
    /// Rendering to an image for tests: no scroll view, which ImageRenderer leaves blank.
    var rendering = false
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// `glass` is kept for older callers; the window has no glass any more.
    init(welcome: Bool = false, glass: Bool = true, state: SettingsState = SettingsState(), rendering: Bool = false) {
        self.welcome = welcome
        self.state = state
        self.rendering = rendering
    }

    var body: some View {
        Panel(cornerRadius: Theme.digital ? 22 : 10) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider2()
                scroller {
                    VStack(alignment: .leading, spacing: 24) {
                        step(1, "shortcut") {
                            PillSwitch(options: Shortcut.allCases.map { ($0, $0.label.lowercased()) }, selection: $settings.shortcut)
                            if settings.shortcutTaken {
                                HStack(spacing: 7) {
                                    StatusDot(on: false)
                                    Text("Another app already uses \(settings.shortcut.label). Pick a different one.").modifier(Prose())
                                }
                            }
                        }
                        step(2, "plan") {
                            PillSwitch(options: Plan.allCases.map { ($0, $0.title.lowercased()) }, selection: $settings.plan)
                            Text(settings.plan == .free
                                 ? "Free opens apps and files by name and finds exact words, in windows and pictures. Nothing leaves this Mac."
                                 : "Jev understands what you mean. It picks the app or file, and finds the answer in the window in front, PDFs and pictures too. NVIDIA Nemotron writes a short answer, thinks harder when you ask, and stands in for Jev.")
                                .modifier(Prose())
                            Link("see the plans ↗", destination: Settings.planPage).font(Theme.mono(12)).foregroundColor(Theme.ink)
                        }
                        if settings.plan == .ai {
                            step(3, "jev key") { keySection }
                            step(4, "nebius key, for nvidia nemotron") { nebiusSection }
                        }
                        step(settings.plan == .ai ? 5 : 3, "reading the screen") {
                            permissionRow(title: "The window in front", detail: "Only when you ask. Never kept.", allowed: state.trusted,
                                          steps: ["Click allow it.", "In System Settings, turn on the switch next to Pareto."]) {
                                WindowReader.askForPermission()
                                WindowReader.openPermissionSettings()
                            }
                            if ScreenShot.supported {
                                permissionRow(title: "Pictures on screen", detail: "Text drawn as a picture, like in Figma. One picture of the window in front, only when its text has no answer, never kept.",
                                              allowed: state.screenAllowed,
                                              steps: ["Click allow it.", "In System Settings, turn on the switch next to Pareto.", "When macOS asks, click Quit & Reopen."]) {
                                    ScreenShot.askForPermission()
                                }
                            }
                        }
                        step(settings.plan == .ai ? 6 : 4, "look") {
                            PillSwitch(options: [(Look.digital, "digital"), (Look.terminal, "terminal")], selection: $settings.look)
                            Text(settings.look == .digital ? "Light grey and black, with numbers like a digital clock." : "Plain black and grey, all monospace.")
                                .modifier(Prose())
                        }
                        step(settings.plan == .ai ? 7 : 5, "voice") {
                            toggle("Hold \(settings.shortcut.label) and speak; let go to run it", $settings.holdToTalk)
                            toggle("Run as soon as I finish speaking with Wispr Flow or macOS dictation", $settings.actAfterVoice)
                        }
                        step(settings.plan == .ai ? 8 : 6, "start") {
                            toggle("Open Pareto when I log in", $settings.launchAtLogin)
                        }
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · on Free nothing leaves this Mac · on the AI plan, what you ask and the text being searched go only to Jev and to Nebius (Nemotron)")
                            .font(Theme.mono(10.5)).foregroundColor(Theme.mute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 30).padding(.vertical, 26)
                }
            }
        }
        .frame(width: 620, height: rendering ? nil : height)
        .padding(28)
        .environment(\.colorScheme, Theme.digital ? .light : .dark)
        .id(settings.look)
        .onAppear {
            // Open at the top: without this the key box takes focus and scrolls the window down.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onReceive(tick) { _ in
            state.trusted = WindowReader.trusted
            state.screenAllowed = ScreenShot.allowed
        }
    }

    @ViewBuilder private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if rendering { content() } else { ScrollView { content() } }
    }

    /// Tall enough to show the first steps without scrolling, but never taller than the screen.
    private var height: CGFloat {
        let want: CGFloat = settings.plan == .ai ? 990 : 870
        let room = (NSScreen.main?.visibleFrame.height ?? 900) - 76
        return max(560, min(want, room))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Wordmark(size: Theme.digital ? 54 : 30)
                    Text("find by meaning").font(Theme.mono(15)).foregroundColor(Theme.ink)
                }
                Text(welcome
                     ? "Press \(settings.shortcut.label) in any app. Open apps and files, or ask about the window in front."
                     : "Settings. Press \(settings.shortcut.label) in any app to open the bar.")
                    .font(Theme.read(13.5)).foregroundColor(Theme.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { NSApp.keyWindow?.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundColor(Theme.ink)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: Theme.line))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 22)
        .background(Theme.band)
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("1. Click").modifier(Prose())
                    Link("get a key ↗", destination: Settings.jevKeys).font(Theme.mono(12.5)).foregroundColor(Theme.ink).underline()
                    Text("and sign in to TypeSafe, or make an account.").modifier(Prose())
                }
                Text("2. Click + Create key, type a name like pareto, and click Create key.").modifier(Prose())
                Text("3. Copy the key (it starts with apikey_). Click in the box below, press ⌘ V, then click save.").modifier(Prose())
            }
            HStack(spacing: 10) {
                Text("›").font(Theme.mono(14, .medium)).foregroundColor(Theme.ink)
                SecureField(settings.hasJevKey ? "a key is saved; paste a new one to replace it" : "paste your Jev key", text: $state.keyInput)
                    .textFieldStyle(.plain).font(Theme.mono(13)).foregroundColor(Theme.ink)
                    .onSubmit(saveKey)
                PillButton(title: "save", action: saveKey)
            }
            .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: Theme.digital ? 14 : 4)
                .strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: Theme.line, dash: Theme.digital ? [3, 3] : [])))
            HStack(spacing: 12) {
                if !state.keyMessage.isEmpty {
                    Text(state.keyMessage).font(Theme.mono(11.5)).foregroundColor(Theme.mute)
                } else if settings.hasJevKey {
                    HStack(spacing: 6) { StatusDot(on: true); Text("key saved").font(Theme.mono(11.5)).foregroundColor(Theme.ink) }
                }
                if settings.hasJevKey {
                    Button("remove key") { settings.removeJevKey(); state.keyMessage = "key removed" }
                        .buttonStyle(.plain).font(Theme.mono(11.5)).foregroundColor(Theme.mute)
                }
            }
        }
    }

    private var nebiusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NVIDIA's open models, run by Nebius Token Factory. Nemotron 3 Super writes a short answer after each search. Nemotron 3 Ultra thinks harder when you press ⌘ Enter: it reads the whole window or PDF. Nemotron 3.5 Lightning finds the answer when there's no Jev key, or Jev can't.")
                .modifier(Prose())
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("1. Click").modifier(Prose())
                    Link("get a key ↗", destination: Settings.nebiusKeys).font(Theme.mono(12.5)).foregroundColor(Theme.ink).underline()
                    Text("and sign in to Nebius Token Factory.").modifier(Prose())
                }
                Text("2. Create an API key and copy it. Click in the box below, press ⌘ V, then click save.").modifier(Prose())
                Text("3. In your Nebius account profile, switch on Zero Data Retention, so Nebius doesn't keep what Pareto sends.").modifier(Prose())
            }
            HStack(spacing: 10) {
                Text("›").font(Theme.mono(14, .medium)).foregroundColor(Theme.ink)
                SecureField(settings.hasNebiusKey ? "a key is saved; paste a new one to replace it" : "paste your Nebius key", text: $state.nebiusInput)
                    .textFieldStyle(.plain).font(Theme.mono(13)).foregroundColor(Theme.ink)
                    .onSubmit(saveNebiusKey)
                PillButton(title: "save", action: saveNebiusKey)
            }
            .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: Theme.digital ? 14 : 4)
                .strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: Theme.line, dash: Theme.digital ? [3, 3] : [])))
            HStack(spacing: 12) {
                if !state.nebiusMessage.isEmpty {
                    Text(state.nebiusMessage).font(Theme.mono(11.5)).foregroundColor(Theme.mute).fixedSize(horizontal: false, vertical: true)
                } else if settings.hasNebiusKey {
                    HStack(spacing: 6) { StatusDot(on: true); Text("key saved").font(Theme.mono(11.5)).foregroundColor(Theme.ink) }
                }
                if settings.hasNebiusKey {
                    Button("check it") { checkNebius() }
                        .buttonStyle(.plain).font(Theme.mono(11.5)).foregroundColor(Theme.ink)
                    Button("remove key") { settings.removeNebiusKey(); state.nebiusMessage = "key removed" }
                        .buttonStyle(.plain).font(Theme.mono(11.5)).foregroundColor(Theme.mute)
                }
            }
            if settings.hasNebiusKey {
                toggle("Write a short answer with Nemotron 3 Super after each search", $settings.writeAnswers)
            }
        }
    }

    private func saveNebiusKey() {
        guard !state.nebiusInput.trimmingCharacters(in: .whitespaces).isEmpty else { state.nebiusMessage = "paste a key first"; return }
        state.nebiusMessage = settings.saveNebiusKey(state.nebiusInput) ? "saved to your Keychain" : "couldn't save it; try again"
        state.nebiusInput = ""
        if settings.hasNebiusKey { checkNebius() }
    }

    /// Lists the key's models on Nebius, which costs nothing, and says whether all three are there.
    private func checkNebius() {
        state.nebiusMessage = "checking…"
        let state = state
        Task { @MainActor in
            let s = await Nemotron.shared.status()
            let models = s.models.map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: "  ")
            state.nebiusMessage = models.isEmpty ? s.detail : "\(s.detail) · \(models)"
        }
    }

    /// One permission: what it's for, whether it's allowed, the steps, and the button.
    private func permissionRow(title: String, detail: String, allowed: Bool, steps: [String], allow: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider2(dashed: false)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.read(14.5, .medium)).foregroundColor(Theme.ink)
                    Text(detail).font(Theme.read(12.5)).foregroundColor(Theme.mute).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    StatusDot(on: allowed)
                    Text(allowed ? "allowed" : "not allowed").font(Theme.mono(11.5)).foregroundColor(allowed ? Theme.ink : Theme.mute)
                    if !allowed { PillButton(title: "allow it", primary: false, action: allow) }
                }
                .layoutPriority(1)
            }
            if !allowed {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, text in
                        Text("\(i + 1). \(text)").font(Theme.read(12.5)).foregroundColor(Theme.soft)
                    }
                }
            }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(String(format: "%02d", n)).font(Theme.display(Theme.digital ? 20 : 13)).foregroundColor(Theme.ink)
                .lineLimit(1).fixedSize()
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 11) {
                Theme.label(title)
                content()
            }
        }
    }

    private func toggle(_ text: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Text(text).modifier(Prose()) }
            .toggleStyle(.switch)
            .tint(Theme.ink)
    }

    private func saveKey() {
        guard !state.keyInput.trimmingCharacters(in: .whitespaces).isEmpty else { state.keyMessage = "paste a key first"; return }
        state.keyMessage = settings.saveJevKey(state.keyInput) ? "saved to your Keychain" : "couldn't save it; try again"
        state.keyInput = ""
    }
}

private struct Prose: ViewModifier {
    func body(content: Content) -> some View {
        content.font(Theme.read(13.5)).foregroundColor(Theme.soft).fixedSize(horizontal: false, vertical: true)
    }
}
