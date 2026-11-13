// What the bar does. As you type it lists apps, files, "find in this window" and a web
// search, all found on this Mac. On the AI plan, Jev then works out what you meant: which
// app, which file, or a question about the front window (Nemotron Lightning when Jev can't).
// Enter (or a pause after speaking) runs the top choice. After a search by meaning, Nemotron 3
// Super writes a short answer, and ⌘ Enter has Nemotron 3 Ultra think harder.

import AppKit
import ApplicationServices
import PDFKit

enum RowKind: Hashable {
    case app(AppEntry)
    case file(FileHit)
    case window
    case web
    case sum(String)
}

struct Row: Identifiable, Hashable {
    let kind: RowKind
    let title: String
    let detail: String
    var jev = false

    var id: String {
        switch kind {
        case .app(let a): return "app:" + a.url.path
        case .file(let f): return "file:" + f.url.path
        case .window: return "window"
        case .web: return "web"
        case .sum: return "sum"
        }
    }
    /// A PDF or picture file, which Tab can ask about without opening it.
    var canAsk: Bool {
        if case .file(let f) = kind { return PDFReader.canRead(f.url) }
        return false
    }
    var tag: String {
        switch kind {
        case .app: return "app"
        case .file: return "file"
        case .window: return "window"
        case .web: return "web"
        case .sum: return "copy"
        }
    }
}

enum Status: Equatable {
    case none
    case busy(String)
    case ok(String, String)
    case miss(String, String)
    case error(String)
}

/// One place in the front window (or its PDF) that answers the question.
struct Match {
    let passage: TextTools.Passage
    let score: Double
    var sentence: String?
    var element: AXUIElement?
    /// When the passage was read from a picture: its lines and where they are (page points in
    /// a PDF, screen points in a window), so the answer can be outlined.
    var pictureLines: [OCRLine] = []
}

struct Answer {
    let question: String
    let source: String
    let appName: String
    var matches: [Match]
    var index = 0
    let pdf: PDFText?
    let sure: Double
    let ms: Int
    /// Found by meaning (Jev, Lightning or Ultra), not word for word.
    let usedJev: Bool
    /// When it was found, so the meter can fill in once.
    var arrived = Date()
    /// Which model found it: "Jev", "Lightning" or "Ultra". Nil for word for word.
    var engine: String? = nil
    /// The short written answer: Nemotron 3 Super's after a search, or Ultra's after think harder.
    var written: String? = nil
    /// Who wrote it and how long it took, such as "nemotron 3 super · 0.9 s".
    var writtenBy: String? = nil
    var writing = false
    var writeFailed: String? = nil

    /// Ultra may answer without pointing to any part of the text, so there can be no match.
    var current: Match? { matches.indices.contains(index) ? matches[index] : nil }
    /// Jev and Lightning say how sure they are; Ultra doesn't.
    var showsSure: Bool { usedJev && engine != Tier.deep.short }
    var place: String {
        if let page = current?.passage.page { return "page \(page + 1)" }
        return appName
    }
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var rows: [Row] = []
    @Published var selected = 0
    @Published var status: Status = .none
    @Published var answer: Answer?
    @Published var needsPermission = false
    /// Hold-to-talk is on: the bar shows what's being heard.
    @Published var listening = false
    @Published private(set) var front: NSRunningApplication?

    let settings = Settings.shared
    var close: (_ restoreFront: Bool) -> Void = { _ in }

    private var files: [FileHit] = []
    private let fileSearch = FileSearch()
    private var routeTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var voiceRun = false
    /// Enter was pressed while Jev was still reading the request: run its pick when it answers.
    private var enterPending = false
    private var routing = false
    /// The front window's title, when reading windows is allowed; it helps Jev tell questions
    /// about the page from other requests.
    private var frontTitle: String?
    private var generation = 0
    private var filesDone: (() -> Void)?
    private var filesReady = false
    /// ⌘ Enter was pressed: the next read of the window or PDF goes to Nemotron 3 Ultra.
    private var deepMode = false
    /// What Ultra is doing, for the status line while it streams.
    private var deepDoing = ""

    var frontName: String { front?.localizedName ?? "this window" }

    // MARK: Opening

    /// Apps that are never "the window in front": this app, and the lock screen.
    private static let notFront: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.dock"]

    func prepare(front app: NSRunningApplication?) {
        let id = app?.bundleIdentifier ?? ""
        front = id == Bundle.main.bundleIdentifier || Self.notFront.contains(id) ? nil : app
        query = ""
        rows = []
        selected = 0
        status = .none
        answer = nil
        needsPermission = false
        generation += 1
        deepMode = false
        routeTask?.cancel()
        windowTask?.cancel()
        fileSearch.cancel()
        rows = Self.recentRows()
        enterPending = false
        frontTitle = nil
        DispatchQueue.global(qos: .userInitiated).async { _ = AppIndex.all() }
        if let app = front, WindowReader.trusted {
            let gen = generation
            Task.detached(priority: .userInitiated) {
                let title = WindowReader.title(of: app)
                await MainActor.run { if gen == self.generation { self.frontTitle = title } }
            }
        }
    }

    /// What was opened through the bar lately, still on disk, newest first.
    static func recentRows() -> [Row] {
        UsageLog.recent().prefix(5).compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            if url.pathExtension == "app" {
                let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                return Row(kind: .app(AppEntry(name: name, url: url)), title: name, detail: "recent")
            }
            let hit = FileHit(url: url, name: url.lastPathComponent, kind: "recent file", modified: nil)
            return Row(kind: .file(hit), title: hit.name, detail: "recent · \(hit.folder)")
        }
    }

    // MARK: Typing

    /// `burst`: the text arrived all at once, which is how Wispr Flow and other dictation type.
    func queryChanged(_ text: String, burst: Bool, spoken: Bool = false) {
        query = text
        generation += 1
        let gen = generation
        routeTask?.cancel()
        windowTask?.cancel()
        answer = nil
        needsPermission = false
        deepMode = false
        voiceRun = spoken || (burst && settings.actAfterVoice)
        enterPending = false
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            rows = Self.recentRows()
            selected = 0
            status = .none
            fileSearch.cancel()
            return
        }
        files = []
        filesReady = false
        rows = localRows(q)
        selected = 0
        status = .none

        fileSearch.run(q, limit: 40) { [weak self] hits in
            guard let self, gen == self.generation else { return }
            self.files = hits
            self.filesReady = true
            self.rows = self.localRows(q)
            self.filesDone?()
            self.filesDone = nil
        }

        routing = false
        if settings.plan == .ai && q.count >= 3 && Calculator.evaluate(q) == nil {
            routing = true
            routeTask = Task { [weak self] in
                // Wait for a pause in typing (not after speaking), then for the file search.
                if !burst && !spoken { try? await Task.sleep(nanoseconds: 350_000_000) }
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                await self.waitForFiles(timeout: 0.9)
                guard !Task.isCancelled, gen == self.generation else { return }
                await self.route(q, gen: gen)
                if gen == self.generation { self.routing = false }
            }
        } else if voiceRun {
            routeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: spoken ? 300_000_000 : 700_000_000)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                await self.waitForFiles(timeout: 0.8)
                guard gen == self.generation else { return }
                self.rows = self.localRows(q)
                if self.safeToRunTop(q, sure: 0) { self.runSelected() } else { self.voiceRun = false }
            }
        }
    }

    private func waitForFiles(timeout: TimeInterval) async {
        if filesReady { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish = {
                if finished { return }
                finished = true
                done.resume()
            }
            filesDone = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private static let questionWords: Set<String> = ["what", "when", "who", "whom", "why", "how", "where", "does", "do", "did",
                                                     "is", "are", "was", "which", "can", "should", "will", "summarize", "explain"]

    /// Rows found on this Mac, in a sensible order before Jev (or instead of it).
    func localRows(_ q: String) -> [Row] {
        let lower = q.lowercased()
        let first = lower.split(separator: " ").first.map(String.init) ?? ""
        let apps = AppIndex.search(q, limit: 4)
        let appScore = apps.first.map { AppIndex.match($0.name, AppIndex.stripCommand(q)) } ?? 0
        let wantsApp = ["open", "launch", "start", "switch", "run"].contains(first)
        let asksWindow = Self.isQuestion(q)

        let appRows = apps.map { Row(kind: .app($0), title: $0.name, detail: $0.url.deletingLastPathComponent().path) }
        // One short word that names an app ("calc"): only files named like it, not every
        // file that happens to contain the word.
        let oneWord = !lower.contains(" ") && lower.count <= 12
        let shown = oneWord && appScore >= 80 ? files.filter { $0.nameMatches > 0 } : files
        let fileRows = shown.prefix(6).map { Row(kind: .file($0), title: $0.name, detail: "\($0.kind) · \($0.folder)") }
        var windowRow: [Row] = []
        if front != nil {
            windowRow = [Row(kind: .window, title: "find “\(Self.short(q))” in \(frontName)",
                             detail: settings.plan == .ai ? "search what's on screen by meaning" : "search what's on screen, word for word")]
        }
        let webTarget = Self.webURL(q)
        let isSite = webTarget?.host != "www.google.com"
        let webRow = [Row(kind: .web,
                          title: isSite ? "open \(webTarget?.host ?? q)" : "search the web for “\(Self.short(Self.webTerms(q)))”",
                          detail: "opens your browser")]

        if let value = Calculator.evaluate(q) {
            let result = Calculator.format(value)
            return [Row(kind: .sum(result), title: "= \(result)", detail: "↵ copies the answer")] + appRows.prefix(1) + webRow
        }
        if asksWindow && !wantsApp { return windowRow + appRows.filter { _ in appScore >= 90 } + fileRows + webRow }
        if wantsApp || appScore >= 80 { return appRows + fileRows + windowRow + webRow }
        return fileRows + appRows + windowRow + webRow
    }

    /// A site named in the request opens directly ("go to youtube.com"); anything else is
    /// searched for, without the "search the web for" part.
    static func webURL(_ q: String) -> URL? {
        let lower = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = lower.range(of: "(https?://)?([a-z0-9-]+\\.)+[a-z]{2,}(/[^\\s]*)?", options: .regularExpression) {
            let site = String(lower[r])
            return URL(string: site.hasPrefix("http") ? site : "https://" + site)
        }
        var terms = lower
        for prefix in ["search the web for ", "search the internet for ", "search google for ", "google search ", "google ",
                       "look up ", "search for ", "search ", "web search "] where terms.hasPrefix(prefix) {
            terms = String(terms.dropFirst(prefix.count))
            break
        }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: terms)]
        return c.url
    }

    static func webTerms(_ q: String) -> String {
        guard let url = webURL(q), let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return q }
        return c.queryItems?.first { $0.name == "q" }?.value ?? q
    }

    static func isQuestion(_ q: String) -> Bool {
        let first = q.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return q.trimmingCharacters(in: .whitespaces).hasSuffix("?") || questionWords.contains(first)
    }

    static func short(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count > 42 ? String(t.prefix(41)) + "…" : t
    }

    // MARK: Jev works out what you meant

    struct Route {
        let intent: String
        let intentSure: Double
        let app: AppEntry?
        let appSure: Double
        let fileOrder: [FileHit]
        let fileSure: Double
        let ms: Int
        /// "Jev", or "Lightning" when Nemotron stood in, and why.
        var engine = "Jev"
        var because: String? = nil
        /// For the status line: "Jev · 120 ms", or "Lightning · 640 ms · Jev out of funds".
        var took: String { [engine, "\(ms) ms", because].compactMap { $0 }.joined(separator: " · ") }
    }

    static func routeRequest(_ q: String, front: String?, title: String?, apps: [AppEntry], files: [FileHit]) -> (String, [String: [String: Any]]) {
        let today = DateFormatter()
        today.dateFormat = "EEEE d MMMM yyyy"
        var state = "Request: \"\(q)\"\nToday is \(today.string(from: Date()))."
        if let front { state += "\nThe window in front is \(front)" + ((title?.isEmpty ?? true) ? "." : ": \"\(title!)\".") }
        var questions: [String: [String: Any]] = [
            "intent": Jev.choice("What does the person want the computer to do?", [
                JevOption(id: "open_app", text: "Open or switch to an app"),
                JevOption(id: "open_file", text: "Open one specific file, document, photo or folder on this computer"),
                JevOption(id: "find_files", text: "See files that match a description, without naming one file"),
                JevOption(id: "find_in_window", text: "Answer a question or find something using what is already on screen: the page, document, email, chat or PDF open in the front window. Most questions (what, when, who, how, why, does...) are about the front window"),
                JevOption(id: "web", text: "Search the internet or open a website, when the person asks for the web, Google, or a site by name"),
            ]),
        ]
        let appOptions = apps.prefix(Jev.maxOptions - 1).enumerated().map { JevOption(id: "a\($0.offset + 1)", text: $0.element.name) }
        questions["app"] = Jev.choice("Which app does the request mean?", appOptions + [JevOption(id: "none", text: "None of these apps")])
        if !files.isEmpty {
            let fileOptions = files.prefix(Jev.maxOptions - 1).enumerated().map { JevOption(id: "f\($0.offset + 1)", text: $0.element.described) }
            questions["file"] = Jev.choice("Which file does the request mean?", fileOptions + [JevOption(id: "none", text: "None of these files")])
        }
        return (state, questions)
    }

    static func readRoute(_ answers: JevAnswers, apps: [AppEntry], files: [FileHit], question: Bool = false) -> Route {
        var intent = answers.choice("intent")
        if question, intent.pick == "web", (intent.probabilities["web"] ?? 0) < 0.75,
           (intent.probabilities["find_in_window"] ?? 0) >= 0.15 {
            intent.pick = "find_in_window"
        }
        let app = answers.choice("app")
        let file = answers.choice("file")
        var appEntry: AppEntry?
        if let pick = app.pick, pick.hasPrefix("a"), let i = Int(pick.dropFirst()), i >= 1, i <= apps.count { appEntry = apps[i - 1] }
        let order = files.enumerated()
            .map { ($0.element, file.probabilities["f\($0.offset + 1)"] ?? 0) }
            .sorted { $0.1 > $1.1 }
        return Route(intent: intent.pick ?? "find_in_window",
                     intentSure: intent.probabilities[intent.pick ?? ""] ?? 0,
                     app: appEntry,
                     appSure: app.probabilities[app.pick ?? ""] ?? 0,
                     fileOrder: order.map(\.0),
                     fileSure: order.first?.1 ?? 0,
                     ms: answers.ms)
    }

    private func route(_ q: String, gen: Int) async {
        status = .busy("asking \(Meaning.finder)")
        let apps = AppIndex.all()
        let (state, questions) = Self.routeRequest(q, front: front?.localizedName, title: frontTitle, apps: apps, files: files)
        do {
            let (answers, engine, because) = try await Meaning.ask(state: state, questions: questions)
            guard gen == generation, !Task.isCancelled else { return }
            var r = Self.readRoute(answers, apps: apps, files: files, question: Self.isQuestion(q))
            r.engine = engine
            r.because = because
            apply(r, q)
            if enterPending {
                enterPending = false
                runSelected()
            } else if voiceRun {
                let sure = r.intent == "open_app" ? min(r.intentSure, r.appSure) : r.intent == "open_file" ? min(r.intentSure, r.fileSure) : r.intentSure
                if safeToRunTop(q, sure: sure) { runSelected() } else { voiceRun = false }
            }
        } catch is CancellationError {
        } catch where error is JevError || error is NemotronError {
            guard gen == generation else { return }
            status = .error(Meaning.plain(error))
            if enterPending || (voiceRun && safeToRunTop(q, sure: 0)) { runSelected() }
            voiceRun = false
            enterPending = false
        } catch {
            guard gen == generation else { return }
            status = .error(error.localizedDescription)
        }
    }

    /// Puts Jev's pick first and says what it thinks you meant.
    private func apply(_ r: Route, _ q: String) {
        let pct = { (x: Double) in "\(Int((x * 100).rounded()))%" }
        let base = localRows(q)
        var picked: [Row] = []
        var rest = base
        switch r.intent {
        case "open_app" where r.app == nil || r.appSure < 0.3:
            status = .miss("not sure which app; pick one", "\(r.took)")
        case "open_app":
            let app = r.app!
            picked = [Row(kind: .app(app), title: app.name, detail: app.url.deletingLastPathComponent().path, jev: true)]
            status = .ok("open \(app.name)", "\(pct(min(r.intentSure, r.appSure))) sure · \(r.took)")
            // Sure it's an app: files that only happen to contain the words would just be noise.
            if r.appSure >= 0.6 {
                var files = 0
                rest.removeAll { row in
                    guard case .file(let f) = row.kind else { return false }
                    files += 1
                    return f.nameMatches == 0 || files > 2
                }
            }
        case "open_file", "find_files":
            let order = r.intent == "find_files" && r.fileSure < 0.3 ? files : r.fileOrder
            let fileRows = order.prefix(6).enumerated().map { i, f in
                Row(kind: .file(f), title: f.name, detail: "\(f.kind) · \(f.folder)", jev: i == 0 && r.fileSure >= 0.3)
            }
            if fileRows.isEmpty {
                status = .miss("no matching files found", "\(r.took)")
            } else {
                picked = Array(fileRows)
                if r.intent == "find_files" {
                    let n = r.fileOrder.count
                    status = .ok("\(n)\(n >= 40 ? "+" : "") matching \(n == 1 ? "file" : "files"), newest first", "\(r.took)")
                } else {
                    status = r.fileSure >= 0.3
                        ? .ok("open \(r.fileOrder[0].name)", "\(pct(r.fileSure)) sure · \(r.took)")
                        : .miss("not sure which file; pick one", "\(r.took)")
                }
            }
        case "web":
            picked = base.filter { if case .web = $0.kind { return true } else { return false } }
            status = .ok("search the web", "\(pct(r.intentSure)) sure · \(r.took)")
        default:
            picked = base.filter { if case .window = $0.kind { return true } else { return false } }
            if !picked.isEmpty { picked[0].jev = true }
            status = .ok(front == nil ? "search what's on screen" : "search \(frontName)", "\(pct(r.intentSure)) sure · \(r.took)")
        }
        let ids = Set(picked.map(\.id))
        rest.removeAll { ids.contains($0.id) }
        rows = picked + rest
        selected = 0
    }

    // MARK: Moving and running

    func move(_ by: Int) {
        if var a = answer, a.matches.count > 1 {
            a.index = (a.index + by + a.matches.count) % a.matches.count
            answer = a
            pickSentence()
            return
        }
        guard !rows.isEmpty else { return }
        selected = (selected + by + rows.count) % rows.count
    }

    func submit() {
        if answer != nil { showAnswer(); return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // On the AI plan, a phrase ("the pdf about my taxes") waits for Jev's reading of it,
        // unless the top row is already an exact app name.
        let exactApp: Bool = {
            guard let row = rows.first, case .app(let app) = row.kind else { return false }
            return AppIndex.match(app.name, AppIndex.stripCommand(q)) >= 90
        }()
        // Moved to a row with the arrows: that's the choice, no waiting.
        if settings.plan == .ai, routing, selected == 0, q.split(separator: " ").count >= 2, !exactApp {
            enterPending = true
            status = .busy("asking \(Meaning.finder)")
            return
        }
        runSelected()
    }

    /// Spoken or pasted text runs by itself only when that can't surprise anyone: a sum, a
    /// question about the window, an app named outright, or something Jev is sure about.
    /// Otherwise the rows wait for Enter.
    func safeToRunTop(_ q: String, sure: Double) -> Bool {
        guard let row = rows.first else { return false }
        switch row.kind {
        case .sum, .window: return true
        case .app(let app): return sure >= 0.6 || AppIndex.match(app.name, AppIndex.stripCommand(q)) >= 80
        case .file: return row.jev && sure >= 0.7
        case .web: return sure >= 0.8
        }
    }

    func runSelected() {
        voiceRun = false
        guard rows.indices.contains(selected) else { return }
        run(rows[selected])
    }

    func run(_ row: Row) {
        switch row.kind {
        case .app(let app):
            UsageLog.record(app.url.path)
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
            close(false)
        case .file(let file):
            UsageLog.record(file.url.path)
            NSWorkspace.shared.open(file.url)
            close(false)
        case .web:
            if let url = Self.webURL(query) { NSWorkspace.shared.open(url) }
            close(false)
        case .window:
            searchWindow()
        case .sum(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            status = .ok("copied \(result)", "")
        }
    }

    /// Tab: ask the question about the selected PDF (without opening it), or the window in front.
    func tab() {
        guard rows.indices.contains(selected) else { return }
        switch rows[selected].kind {
        case .file(let f) where PDFReader.canRead(f.url):
            askFile(f.url)
        case .window:
            searchWindow()
        default:
            break
        }
    }

    /// ⌘↵: think harder about the window or the PDF picked (or the answer showing), and
    /// otherwise show the picked file or app in Finder.
    func commandEnter() {
        let row = rows.indices.contains(selected) ? rows[selected] : nil
        let onWindow: Bool = { if case .window = row?.kind { return true } else { return false } }()
        if answer != nil || onWindow || row?.canAsk == true { thinkHarder() } else { revealSelected() }
    }

    /// Nemotron 3 Ultra reads all of the window or the PDF, reasons, answers, and points to the
    /// parts it used. The reading is the same as a normal search; only the asking differs.
    func thinkHarder() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard settings.plan == .ai else { status = .error("Think harder is part of the AI plan."); return }
        guard Nemotron.shared.hasKey else { status = .error("Think harder uses Nemotron 3 Ultra. Add a Nebius key in settings."); return }
        let picked: URL? = {
            if answer == nil, rows.indices.contains(selected), case .file(let f) = rows[selected].kind, PDFReader.canRead(f.url) { return f.url }
            return answer?.pdf?.url
        }()
        answer = nil
        deepMode = true
        if let picked { askFile(picked) } else { searchWindow() }
    }

    /// Shows the file in Finder instead of opening it (⌘↵ on a file or app).
    func revealSelected() {
        guard rows.indices.contains(selected) else { return }
        switch rows[selected].kind {
        case .file(let f): NSWorkspace.shared.activateFileViewerSelecting([f.url]); close(false)
        case .app(let a): NSWorkspace.shared.activateFileViewerSelecting([a.url]); close(false)
        default: break
        }
    }

    func escape() {
        if answer != nil || needsPermission {
            answer = nil
            needsPermission = false
            status = .none
            return
        }
        close(true)
    }

    // MARK: Searching the front window

    func searchWindow() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app = front, !q.isEmpty else { return }
        guard WindowReader.trusted else {
            // Screen reading alone still works: the picture of the window is read instead.
            if ScreenShot.allowed {
                routeTask?.cancel()
                searchPictureOnly()
                return
            }
            needsPermission = true
            status = .error("Pareto needs permission to read the front window.")
            return
        }
        routeTask?.cancel()
        let gen = generation
        status = .busy("reading \(frontName)")
        windowTask = Task { [weak self] in
            guard let self else { return }
            let content = await Task.detached(priority: .userInitiated) { WindowReader.read(app) }.value
            guard gen == self.generation, !Task.isCancelled else { return }
            guard let content else {
                self.status = .miss("couldn't read \(self.frontName)", "no window open")
                return
            }
            // A PDF or picture file is read from the file. If it can't be opened (a PDF behind a
            // sign-in, say), the window's own text is searched instead.
            if let url = content.file, await self.searchPDF(url, question: q, appName: content.appName, gen: gen) { return }
            guard gen == self.generation, !Task.isCancelled else { return }
            let (passages, elements) = Self.windowPassages(content.texts)
            let source = content.title.isEmpty ? content.appName : "\(content.appName) · \(content.title)"
            if !passages.isEmpty {
                let found = self.settings.plan == .ai
                    ? await self.meaningSearch(q, passages: passages, elements: elements, pdf: nil, source: source, app: content.appName, gen: gen)
                    : self.wordSearch(q, passages: passages, elements: elements, pdf: nil, source: source, app: content.appName, ms: content.ms)
                if found { return }
            }
            guard gen == self.generation, !Task.isCancelled else { return }
            await self.searchPicture(q, of: content, source: source, gen: gen, hadText: !passages.isEmpty)
        }
    }

    /// Asks the picture of the front window only, as if its text had no answer: when only
    /// screen reading is allowed, and for the checks (a test link). Needs the Screen Recording
    /// permission, not Accessibility.
    func searchPictureOnly() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app = front, !q.isEmpty else { return }
        let content = WindowContent(appName: app.localizedName ?? "this app", bundleID: app.bundleIdentifier, pid: app.processIdentifier,
                                    title: "", texts: [], file: nil, frame: nil, ms: 0)
        let gen = generation
        windowTask = Task { [weak self] in
            await self?.searchPicture(q, of: content, source: content.appName, gen: gen, hadText: false)
        }
    }

    /// The window's text doesn't answer, or it has none: its text may be drawn as a picture
    /// (Figma, a photo on a page). With the Screen Recording permission, Vision reads a picture
    /// of the window; the picture isn't kept.
    private func searchPicture(_ q: String, of content: WindowContent, source: String, gen: Int, hadText: Bool) async {
        guard ScreenShot.allowed else {
            let hint = ScreenShot.supported ? "allow screen reading in settings to check pictures too" : "\(content.ms) ms"
            if hadText {
                if case .miss(let what, _) = status { status = .miss(what, hint) }
            } else {
                status = .miss("no text to search in \(frontName)", hint)
            }
            return
        }
        status = .busy("reading the picture of \(frontName)")
        let shot = await ScreenShot.within(12) { await ScreenShot.readWindow(pid: content.pid, frame: content.frame) }
        guard gen == generation, !Task.isCancelled else { return }
        guard let shot else {
            status = .miss("couldn't take a picture of \(frontName)", "")
            return
        }
        var blocks: [(text: String, group: Int, page: Int?)] = []
        var lines: [Int: [OCRLine]] = [:]
        for block in shot.blocks {
            lines[blocks.count] = block
            blocks.append((OCR.join(block), 0, nil))
        }
        let passages = TextTools.passages(blocks)
        guard !passages.isEmpty else {
            status = .miss("no text in \(frontName), even in pictures", "\(shot.ms) ms")
            return
        }
        if settings.plan == .ai {
            await meaningSearch(q, passages: passages, elements: [], pdf: nil, lines: lines, source: source,
                                app: content.appName, gen: gen, note: "read from the screen")
        } else {
            wordSearch(q, passages: passages, elements: [], pdf: nil, lines: lines, source: source,
                       app: content.appName, ms: shot.ms, note: "read from the screen")
        }
    }

    /// Asks about a PDF file without opening it: Tab on a PDF in the list, or a PDF in front.
    func askFile(_ url: URL) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        routeTask?.cancel()
        let gen = generation
        windowTask = Task { [weak self] in
            await self?.searchPDF(url, question: q, appName: url.lastPathComponent, gen: gen)
        }
    }

    /// Returns false only when the file can't be opened, so the window's text can be tried.
    @discardableResult
    private func searchPDF(_ url: URL, question q: String, appName: String, gen: Int) async -> Bool {
        let picture = PDFReader.isPicture(url)
        status = .busy(picture ? "reading the picture" : "reading the PDF")
        let started = Date()
        guard let pdf = await PDFReader.read(url) else {
            status = .miss("couldn't open \(url.lastPathComponent)", "")
            return false
        }
        guard gen == generation, !Task.isCancelled else { return true }
        guard !pdf.passages.isEmpty else {
            status = .miss(picture ? "no text found in this picture" : "no text found in this PDF", "")
            return true
        }
        var notes: [String] = []
        if pdf.picturePages > 0, !picture {
            notes.append("\(pdf.picturePages) page\(pdf.picturePages == 1 ? "" : "s") read from pictures")
        }
        if pdf.skippedPages > 0 { notes.append("\(pdf.skippedPages) left out for time") }
        let note = notes.isEmpty ? nil : notes.joined(separator: " · ")
        let what = picture ? "the picture" : "the PDF"
        let source = appName == url.lastPathComponent ? url.lastPathComponent : "\(appName) · \(url.lastPathComponent)"
        if settings.plan == .ai {
            await meaningSearch(q, passages: pdf.passages, elements: [], pdf: pdf, lines: pdf.pictureLines, source: source,
                                app: what, gen: gen, note: note)
        } else {
            wordSearch(q, passages: pdf.passages, elements: [], pdf: pdf, lines: pdf.pictureLines, source: source, app: what,
                       ms: Int(Date().timeIntervalSince(started) * 1000), note: note)
        }
        return true
    }

    /// On-screen text → passages. Runs of text from one paragraph (a web page splits them at
    /// every link) are joined first; each passage remembers the element to scroll to.
    static func windowPassages(_ texts: [ScreenText]) -> ([TextTools.Passage], [AXUIElement]) {
        var blocks: [(text: String, group: Int, page: Int?)] = []
        var elements: [AXUIElement] = []
        var lastGroup = -1
        for t in texts {
            if t.group == lastGroup, !blocks.isEmpty, t.role == "AXStaticText" {
                blocks[blocks.count - 1].text += " " + t.text
            } else {
                blocks.append((t.text, t.group, nil))
                elements.append(t.element)
            }
            lastGroup = t.group
        }
        return (TextTools.passages(blocks), elements)
    }

    private func element(for passage: TextTools.Passage, in elements: [AXUIElement]) -> AXUIElement? {
        guard let i = passage.blocks.first, elements.indices.contains(i) else { return nil }
        return elements[i]
    }

    /// Line ids ("c12") with scores → the matches to show, in that order.
    private func matches(_ hits: [LineHit], passages: [TextTools.Passage], elements: [AXUIElement], pdf: PDFText?,
                         lines: [Int: [OCRLine]]) -> [Match] {
        hits.compactMap { hit -> Match? in
            guard let i = Int(hit.id.dropFirst()), passages.indices.contains(i - 1) else { return nil }
            let p = passages[i - 1]
            return Match(passage: p, score: hit.score, sentence: nil, element: pdf == nil ? element(for: p, in: elements) : nil,
                         pictureLines: p.blocks.flatMap { lines[$0] ?? [] })
        }
    }

    private static func seconds(_ ms: Int) -> String { String(format: "%.1f s", Double(ms) / 1000) }
    private static func words(_ chars: Int) -> String {
        let n = max(1, chars / 6)
        return "\(n.formatted()) \(n == 1 ? "word" : "words")"
    }

    /// Returns true when it found an answer, or hit an error the picture of the window can't fix.
    @discardableResult
    private func meaningSearch(_ q: String, passages: [TextTools.Passage], elements: [AXUIElement], pdf: PDFText?,
                               lines: [Int: [OCRLine]] = [:], source: String, app: String, gen: Int, note: String? = nil) async -> Bool {
        if deepMode {
            deepMode = false
            return await deepSearch(q, passages: passages, elements: elements, pdf: pdf, lines: lines, source: source, app: app, gen: gen, note: note)
        }
        status = .busy("asking \(Meaning.finder)")
        let jevLines = passages.enumerated().map { Line(id: "c\($0.offset + 1)", text: $0.element.text) }
        do {
            let result = try await Meaning.findLines(jevLines, question: q)
            guard gen == generation else { return true }
            let pct = Int((result.exists * 100).rounded())
            let took = [result.engine, "\(result.ms) ms", result.because].compactMap { $0 }.joined(separator: " · ")
            guard result.exists >= 0.5 else {
                status = .miss("not found in \(app)", "\(pct)% sure it's there · \(took)")
                return false
            }
            let hits = result.top.enumerated().filter { $0.offset == 0 || $0.element.score >= 0.02 }.map(\.element)
            let found = matches(hits, passages: passages, elements: elements, pdf: pdf, lines: lines)
            guard !found.isEmpty else { status = .miss("not found in \(app)", took); return false }
            answer = Answer(question: q, source: source, appName: app, matches: found, pdf: pdf,
                            sure: result.exists, ms: result.ms, usedJev: true, engine: result.engine)
            let detail = [note, found.count > 1 ? "1 of \(found.count)" : nil, took].compactMap { $0 }
            status = .ok("\(pct)% sure \(app) answers it", detail.joined(separator: " · "))
            pickSentence()
            writeAnswer()
            return true
        } catch is CancellationError {
            return true
        } catch {
            guard gen == generation else { return true }
            status = .error(Meaning.plain(error))
            return true
        }
    }

    /// Think harder: Nemotron 3 Ultra gets every passage, streams its reasoning and answer, and
    /// names the passages it used. Those become the matches, so ↑↓, the sentence and "show it"
    /// work as usual. Always returns true: there's no picture to fall back to afterwards.
    private func deepSearch(_ q: String, passages: [TextTools.Passage], elements: [AXUIElement], pdf: PDFText?,
                            lines: [Int: [OCRLine]], source: String, app: String, gen: Int, note: String?) async -> Bool {
        let started = Date()
        deepDoing = "reading \(app)"
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                self.status = .busy("nemotron 3 ultra · \(self.deepDoing) · \(Self.seconds(Int(Date().timeIntervalSince(started) * 1000)))")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { ticker.cancel() }
        let all = passages.enumerated().map { Line(id: "c\($0.offset + 1)", text: $0.element.text) }
        do {
            let r = try await Nemotron.shared.thinkHarder(question: q, lines: all, source: source) { [weak self] phase, chars in
                let doing = phase == "writing" ? "writing" : "thinking · \(Self.words(chars))"
                Task { @MainActor in self?.deepDoing = doing }
            }
            ticker.cancel()
            guard gen == generation else { return true }
            let found = matches(r.lines.map { LineHit(id: $0, score: 1) }, passages: passages, elements: elements, pdf: pdf, lines: lines)
            let took = Self.seconds(r.reply.ms)
            let thought = r.reply.thoughtChars > 0 ? " · thought \(Self.words(r.reply.thoughtChars))" : ""
            answer = Answer(question: q, source: source, appName: app, matches: found, pdf: pdf, sure: 1, ms: r.reply.ms, usedJev: true,
                            engine: Tier.deep.short, written: r.answer, writtenBy: "nemotron 3 ultra · \(took)\(thought)")
            let detail = [note, found.count > 1 ? "1 of \(found.count)" : nil, "Ultra · \(took)"].compactMap { $0 }
            status = .ok(found.isEmpty ? "ultra answered" : "ultra used this part of \(app)", detail.joined(separator: " · "))
            pickSentence()
        } catch is CancellationError {
        } catch {
            guard gen == generation else { return true }
            status = .error(Meaning.plain(error))
        }
        return true
    }

    /// Nemotron 3 Super writes a short answer from the best matches, once the sentence is showing.
    private func writeAnswer() {
        guard settings.writeAnswers, Nemotron.shared.hasKey, var a = answer, a.usedJev, a.written == nil else { return }
        a.writing = true
        answer = a
        let question = a.question
        let excerpts = a.matches.prefix(3).map(\.passage.text)
        let source = a.source
        Task { [weak self] in
            var reply: ChatReply?
            var failure: Error?
            do {
                reply = try await Nemotron.shared.answer(question: question, excerpts: excerpts, source: source)
            } catch {
                failure = error
            }
            guard let self, var now = self.answer, now.question == question, now.engine != Tier.deep.short else { return }
            now.writing = false
            if let reply {
                now.written = reply.text
                now.writtenBy = "nemotron 3 super · \(Self.seconds(reply.ms))"
            } else if let failure, !(failure is CancellationError) {
                now.writeFailed = "no written answer: \(Meaning.plain(failure))"
            }
            self.answer = now
        }
    }

    /// Free plan: the passages that contain every word typed, like normal Ctrl+F.
    /// Returns true when some passage has every word.
    @discardableResult
    private func wordSearch(_ q: String, passages: [TextTools.Passage], elements: [AXUIElement], pdf: PDFText?,
                            lines: [Int: [OCRLine]] = [:], source: String, app: String, ms: Int, note: String? = nil) -> Bool {
        let words = TextTools.keywords(q)
        let want = words.isEmpty ? [q.lowercased()] : words
        let hits = passages.filter { p in
            let t = p.text.lowercased()
            return want.allSatisfy { t.contains($0) }
        }
        guard !hits.isEmpty else {
            status = .miss("no matches in \(app)", "\(ms) ms")
            return false
        }
        let matches = hits.prefix(50).map { p -> Match in
            let s = TextTools.sentences(p.text).first { s in want.contains { s.lowercased().contains($0) } }
            return Match(passage: p, score: 1, sentence: s, element: pdf == nil ? element(for: p, in: elements) : nil,
                         pictureLines: p.blocks.flatMap { lines[$0] ?? [] })
        }
        answer = Answer(question: q, source: source, appName: app, matches: Array(matches), pdf: pdf, sure: 1, ms: ms, usedJev: false)
        status = .ok("\(hits.count) \(hits.count == 1 ? "match" : "matches") in \(app)", [note, "\(ms) ms"].compactMap { $0 }.joined(separator: " · "))
        return true
    }

    /// The exact sentence in the current match, picked by a second small call: to Jev, or to
    /// Lightning when Lightning found the passage or Jev can't.
    private func pickSentence() {
        guard let a = answer, a.usedJev, let current = a.current, current.sentence == nil else { return }
        let index = a.index
        let passage = current.passage
        let engine = a.engine ?? "Jev"
        Task { [weak self] in
            let sentences = TextTools.sentences(passage.text)
            let i = (try? await Meaning.pickSentence(sentences, question: a.question, engine: engine)) ?? 0
            guard let self, var now = self.answer, now.question == a.question, now.matches.indices.contains(index) else { return }
            now.matches[index].sentence = sentences.indices.contains(i) ? sentences[i] : nil
            self.answer = now
        }
    }

    /// Takes you to the answer: a PDF opens at its page, other apps scroll to it and glow.
    func showAnswer() {
        guard let a = answer, let m = a.current else { return }
        let pictureBox = m.pictureLines.isEmpty ? nil : OCR.box(of: m.sentence, in: m.pictureLines)
        if let pdf = a.pdf {
            close(false)
            PDFWindow.show(pdf.document, url: pdf.url, page: m.passage.page ?? 0, sentence: m.sentence, box: pictureBox)
            return
        }
        if let pictureBox {
            // Read from a picture of the window: outline the spot it came from.
            let app = front
            close(true)
            app?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { GlowOverlay.shared.show(pictureBox) }
            return
        }
        guard let element = m.element else { return }
        let app = front
        close(true)
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Scroll first, then outline where the answer ended up.
            _ = WindowReader.reveal(element, sentence: m.sentence, passage: m.passage.text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let rect = WindowReader.reveal(element, sentence: m.sentence, passage: m.passage.text) {
                    GlowOverlay.shared.show(rect)
                }
            }
        }
    }

    func copyAnswer() {
        guard let a = answer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.current.map { $0.sentence ?? $0.passage.text } ?? a.written ?? "", forType: .string)
        status = .ok("copied", "")
    }
}
