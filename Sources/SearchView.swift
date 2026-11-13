// The bar. Digital look: a light panel with black type, a › prompt, and the chosen row and the
// answer inverted to black. Terminal look: the same, plain and dark, with a $ prompt. Below the
// prompt are the rows (apps, files, this window, the web) or, after a question about the front
// window, the answer.

import AppKit
import SwiftUI

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var settings = Settings.shared
    /// Rendering to an image for tests: a plain text line stands in for the live text field.
    var rendering = false

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                prompt
                Divider2()
                if model.needsPermission {
                    PermissionCard()
                } else if let answer = model.answer {
                    AnswerView(answer: answer, model: model)
                } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty && model.rows.isEmpty {
                    EmptyState(front: model.front?.localizedName)
                } else {
                    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Theme.label("recent")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 12)
                    }
                    ResultsList(model: model)
                }
                StatusBar(model: model)
            }
        }
        .frame(width: 620)
        .padding(30) // room for the shadow
        .id(settings.look) // redraw everything when the look changes
    }

    private var prompt: some View {
        HStack(spacing: 12) {
            if model.listening {
                Circle().fill(Theme.signal).frame(width: 9, height: 9).padding(.horizontal, 2)
            } else {
                Text(Theme.digital ? "›" : "$").font(Theme.mono(20, .medium)).foregroundColor(Theme.digital ? Theme.ink : Theme.mute)
            }
            if rendering {
                Text(model.query.isEmpty ? "open an app, find a file, or ask about this window" : model.query)
                    .font(Theme.mono(18))
                    .foregroundColor(model.query.isEmpty ? Theme.mute : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                QueryField(model: model)
            }
            if model.listening {
                Text("listening · let go to run").font(Theme.mono(11)).foregroundColor(Theme.ink)
            } else if case .busy = model.status {
                LoadingSegments()
            } else {
                Text(Settings.shared.shortcut.label.lowercased())
                    .font(Theme.mono(10.5)).foregroundColor(Theme.mute)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(Theme.hairline, lineWidth: Theme.line))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }
}

struct EmptyState: View {
    var front: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Theme.label("try")
            example("open slack", "opens an app")
            example("find my tax pdf from march", "finds a file by what it is")
            example(front.map { "what does this \($0 == "Preview" ? "PDF" : "page") say about refunds?" } ?? "what does this page say about refunds?",
                    "answers from the window in front")
            Text("Hold \(Settings.shared.shortcut.label) and speak, or use Wispr Flow. It runs when you stop.")
                .font(Theme.read(12)).foregroundColor(Theme.mute).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 16)
    }
    private func example(_ text: String, _ what: String) -> some View {
        HStack(spacing: 10) {
            Text(text).font(Theme.mono(13)).foregroundColor(Theme.ink)
            Text(what).font(Theme.mono(11)).foregroundColor(Theme.mute)
        }
    }
}

struct ResultsList: View {
    @ObservedObject var model: SearchModel
    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(model.rows.prefix(8).enumerated()), id: \.element.id) { i, row in
                RowView(row: row, selected: i == model.selected, front: model.front)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selected = i; model.runSelected() }
                    .onHover { if $0 { model.selected = i } }
            }
        }
        .padding(8)
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        // Drawn once into a plain 64-pixel bitmap: Finder's icons hold many sizes, and SwiftUI's
        // ImageRenderer (used for the test pictures) dims the whole picture when given those.
        let source = NSWorkspace.shared.icon(forFile: path)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = image.size
            image.addRepresentation(rep)
        } else {
            source.size = image.size
            return source
        }
        cache[path] = image
        return image
    }
}

struct RowView: View {
    let row: Row
    let selected: Bool
    let front: NSRunningApplication?

    var body: some View {
        HStack(spacing: 13) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.read(14.5, selected ? .medium : .regular))
                    .foregroundColor(selected ? Theme.onInvert : Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(row.detail).font(Theme.mono(11)).foregroundColor(selected ? Theme.muteOnInvert : Theme.mute)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if row.jev {
                Text(Theme.digital ? "JEV PICK" : "jev pick").font(Theme.mono(9.5)).tracking(Theme.digital ? 0.8 : 0)
                    .foregroundColor(selected ? Theme.onInvert : Theme.ink)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(selected ? Theme.muteOnInvert : Theme.hairline, lineWidth: Theme.line))
            }
            Text(row.tag + (selected ? " ↵" : "")).font(Theme.mono(11))
                .foregroundColor(selected ? Theme.onInvert : Theme.mute)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.digital ? 13 : 4, style: .continuous).fill(selected ? Theme.invert : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .app(let a): Image(nsImage: Icons.icon(for: a.url.path)).resizable()
        case .file(let f): Image(nsImage: Icons.icon(for: f.url.path)).resizable()
        case .window:
            if let url = front?.bundleURL { Image(nsImage: Icons.icon(for: url.path)).resizable() }
            else { symbol("macwindow") }
        case .web: symbol("globe")
        case .sum: symbol("equal")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .regular))
            .foregroundColor(selected ? Theme.invert : Theme.ink)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.onInvert : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? .clear : Theme.hairline, lineWidth: Theme.line))
    }
}

struct AnswerView: View {
    let answer: Answer
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                Theme.label(where_ + " · " + answer.place + (answer.matches.count > 1 ? " · \(answer.index + 1) of \(answer.matches.count)" : ""))
                Spacer()
                if answer.showsSure {
                    HStack(alignment: .lastTextBaseline, spacing: 1) {
                        Text("\(Int((answer.sure * 100).rounded()))").font(Theme.display(34))
                        Text("%").font(Theme.mono(15, .medium))
                    }
                    .foregroundColor(Theme.ink)
                    .accessibilityLabel("\(Int((answer.sure * 100).rounded())) percent sure")
                }
            }
            if answer.writing || answer.written != nil || answer.writeFailed != nil { written }
            if let m = answer.current { passage(m) }
            HStack(spacing: 8) {
                Text(answer.source).font(Theme.mono(11)).foregroundColor(Theme.mute).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let m = answer.current {
                    PillButton(title: answer.pdf.map { PDFReader.isPicture($0.url) ? "open it ↵" : "open at page \((m.passage.page ?? 0) + 1) ↵" } ?? "show it ↵") { model.showAnswer() }
                }
                PillButton(title: "copy ⌘C", primary: false) { model.copyAnswer() }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    /// Nemotron's short written answer, and who wrote it.
    private var written: some View {
        VStack(alignment: .leading, spacing: 4) {
            if answer.writing {
                Text("nemotron 3 super is writing an answer…").font(Theme.mono(11.5)).foregroundColor(Theme.mute)
            } else if let text = answer.written {
                Text(text).font(Theme.read(14.5)).foregroundColor(Theme.ink).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let by = answer.writtenBy { Text(by).font(Theme.mono(10.5)).foregroundColor(Theme.mute) }
            } else if let failed = answer.writeFailed {
                Text(failed).font(Theme.mono(11)).foregroundColor(Theme.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The sentence that answers, inverted, with the rest of its passage; or the passage until
    /// the sentence is picked.
    @ViewBuilder private func passage(_ m: Match) -> some View {
        if let sentence = m.sentence {
            Text(sentence)
                .font(Theme.read(16.5)).foregroundColor(Theme.onInvert)
                .lineSpacing(2)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.digital ? 5 : 1).fill(Theme.invert))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if context(m).count > 0 {
                Text(context(m)).font(Theme.read(13.5)).foregroundColor(Theme.mute).lineLimit(3)
            }
        } else {
            Text(m.passage.text).font(Theme.read(15)).foregroundColor(Theme.ink).lineLimit(6)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var where_: String {
        answer.pdf.map { PDFReader.isPicture($0.url) ? "in the picture" : "in the pdf" } ?? "in \(answer.appName.lowercased())"
    }

    /// The rest of the passage around the sentence, for context.
    private func context(_ m: Match) -> String {
        guard let s = m.sentence else { return "" }
        let rest = m.passage.text.replacingOccurrences(of: s, with: " … ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let clean = rest.trimmingCharacters(in: CharacterSet(charactersIn: " …"))
        return clean.count < 12 ? "" : clean
    }
}

struct PermissionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(on: false)
                Theme.label("one-time permission")
            }
            Text("To read the window in front, macOS needs you to allow Pareto under Privacy & Security › Accessibility.")
                .font(Theme.read(14.5)).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Text("It only reads the window in front, only when you ask, and never keeps what it read.")
                .font(Theme.read(12.5)).foregroundColor(Theme.mute)
            HStack {
                PillButton(title: "allow it") {
                    WindowReader.askForPermission()
                    WindowReader.openPermissionSettings()
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }
}

struct StatusBar: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            Divider2(dashed: false)
            HStack(spacing: 12) {
                if let a = model.answer, a.showsSure { SegmentMeter(value: a.sure, since: a.arrived) }
                status
                Spacer(minLength: 8)
                hints
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.status {
        case .none:
            EmptyView()
        case .busy(let text):
            Text(text).font(Theme.mono(11.5)).foregroundColor(Theme.ink)
        case .ok(let text, let meta):
            HStack(spacing: 6) {
                if model.answer == nil { Text(text).foregroundColor(Theme.ink).lineLimit(1).truncationMode(.middle) }
                if !meta.isEmpty { Text(meta).foregroundColor(Theme.mute).lineLimit(1) }
            }.font(Theme.mono(11.5))
        case .miss(let text, let meta):
            HStack(spacing: 6) {
                StatusDot(on: false)
                Text(text).foregroundColor(Theme.ink).lineLimit(1)
                if !meta.isEmpty { Text(meta).foregroundColor(Theme.mute).lineLimit(1) }
            }.font(Theme.mono(11.5))
        case .error(let text):
            HStack(spacing: 6) {
                StatusDot(on: false)
                Text(text).foregroundColor(Theme.ink).lineLimit(1).truncationMode(.tail)
            }.font(Theme.mono(11.5))
        }
    }

    private var hints: some View {
        let row = model.rows.indices.contains(model.selected) ? model.rows[model.selected] : nil
        let onWindow: Bool = { if case .window = row?.kind { return true } else { return false } }()
        // ⌘↵ thinks harder (Nemotron 3 Ultra) on the window, a PDF, or an answer; elsewhere it's Finder.
        let deep = model.settings.plan == .ai && model.settings.hasNebiusKey
        let keys: [(String, String)] = model.answer != nil
            ? (deep ? [("↵", "show"), ("⌘↵", "think harder"), ("↑↓", "others"), ("esc", "back")] : [("↵", "show"), ("↑↓", "others"), ("esc", "back")])
            : row?.canAsk == true
                ? [("↵", "open"), ("⇥", "ask it"), deep ? ("⌘↵", "think harder") : ("↑↓", "choose"), ("esc", "close")]
                : onWindow && deep
                    ? [("↵", "search"), ("⌘↵", "think harder"), ("↑↓", "choose"), ("esc", "close")]
                    : [("↵", "open"), ("↑↓", "choose"), ("⌘↵", "finder"), ("esc", "close")]
        return HStack(spacing: 11) {
            ForEach(keys, id: \.0) { k, what in
                HStack(spacing: 4) {
                    Text(k).foregroundColor(Theme.ink)
                    Text(what).foregroundColor(Theme.mute)
                }
            }
        }
        .font(Theme.mono(10.5))
        .fixedSize()
    }
}

// MARK: - The text field

/// An NSTextField, because it handles typing, arrow keys and dictation exactly like the rest
/// of macOS, including Wispr Flow's pasting.
struct QueryField: NSViewRepresentable {
    @ObservedObject var model: SearchModel

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        style(field)
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Search")
        return field
    }

    /// The look's font and colours; set again when the look changes.
    private func style(_ field: NSTextField) {
        field.font = Theme.nsMono(18)
        field.textColor = Theme.nsInk
        field.placeholderAttributedString = NSAttributedString(
            string: "open an app, find a file, or ask about this window",
            attributes: [.foregroundColor: Theme.nsMute, .font: Theme.nsMono(18)])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Theme.nsInk
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.textColor != Theme.nsInk { style(field) }
        if field.stringValue != model.query {
            field.stringValue = model.query
            context.coordinator.last = model.query
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: SearchModel
        var last = ""
        init(model: SearchModel) { self.model = model }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue
            // Dictation (Wispr Flow, macOS dictation) and pasting put several characters in at once.
            let burst = text.count - last.count >= 4
            last = text
            Task { @MainActor in model.queryChanged(text, burst: burst) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): Task { @MainActor in model.move(-1) }; return true
            case #selector(NSResponder.moveDown(_:)): Task { @MainActor in model.move(1) }; return true
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.command) { Task { @MainActor in model.commandEnter() } }
                else { Task { @MainActor in model.submit() } }
                return true
            case #selector(NSResponder.cancelOperation(_:)): Task { @MainActor in model.escape() }; return true
            case #selector(NSResponder.insertTab(_:)): Task { @MainActor in model.tab() }; return true
            default: return false
            }
        }
    }
}

final class FocusField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Theme.nsInk
        }
        return ok
    }
}
