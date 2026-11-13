// Checks that run from Terminal, without the bar on screen:
//
//   Pareto --selftest [--jev]     apps, file search, text tools, PDFs; --jev adds real Jev calls
//   Pareto --nemotron             the Nemotron paths: finding (Jev first, Lightning standing in),
//                                 the sentence, Super's answer, Ultra thinking harder, routing
//   Pareto --route "open slack"   what the bar would list, and (with a key) what Jev picks
//   Pareto --pdf file.pdf "question"   (a picture file works too)
//   Pareto --ocr picture.png           the blocks of text Vision finds, and where
//   Pareto --screen "App Name"         a picture of that app's window, read the same way
//   Pareto --render <folder>      pictures of the bar and settings, for checking the look
//
// Real Jev calls need CTRLF_JEV_KEY in the environment; the key is never printed. Nemotron needs
// CTRLF_NEBIUS_KEY, and CTRLF_NEBIUS_BASE points it at the stand-in server
// (node tests/mock-tokenfactory.mjs). CTRLF_NO_JEV=1 hides a saved Jev key, so Lightning finds.

import AppKit
import ApplicationServices
import CoreText
import PDFKit
import SwiftUI

@MainActor
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String) {
        if !ok { failures += 1 }
        print("\(ok ? "✓" : "✗") \(label)")
    }

    static func run(_ args: [String]) async {
        if let i = args.firstIndex(of: "--route"), args.count > i + 1 {
            await route(args[i + 1], jev: Settings.shared.jevKey != nil || Settings.shared.nebiusKey != nil)
        } else if let i = args.firstIndex(of: "--pdf"), args.count > i + 2 {
            await pdf(URL(fileURLWithPath: args[i + 1]), args[i + 2])
        } else if let i = args.firstIndex(of: "--screen"), args.count > i + 1 {
            await screen(args[i + 1])
        } else if let i = args.firstIndex(of: "--ocr"), args.count > i + 1 {
            ocr(URL(fileURLWithPath: args[i + 1]))
        } else if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
            render(to: URL(fileURLWithPath: args[i + 1]))
            await renderGuide(to: URL(fileURLWithPath: args[i + 1]))
        } else if let i = args.firstIndex(of: "--icon"), args.count > i + 1 {
            icon(to: URL(fileURLWithPath: args[i + 1]))
        } else if args.contains("--nemotron") {
            await nemotron()
        } else {
            await selftest(jev: args.contains("--jev"))
        }
        if Jev.shared.tokensUsed > 0 { print("Jev input tokens: \(Jev.shared.tokensUsed)") }
        if Nemotron.shared.tokensUsed > 0 { print("Nemotron tokens: \(Nemotron.shared.tokensUsed)") }
        print(failures == 0 ? "All passed" : "\(failures) FAILED")
    }

    // MARK: The self-test

    static func selftest(jev: Bool) async {
        // Apps
        let apps = AppIndex.all()
        check(apps.count > 20, "found \(apps.count) apps")
        check(AppIndex.search("open safari").first?.name == "Safari", "\"open safari\" → Safari")
        check(AppIndex.search("calc").first?.name == "Calculator", "\"calc\" → Calculator")
        check(AppIndex.search("launch the notes app").first?.name == "Notes", "\"launch the notes app\" → Notes")
        check(AppIndex.match("System Settings", "ss") >= 60, "initials: \"ss\" matches System Settings")
        check(AppIndex.stripCommand("Open up Slack please") == "slack", "strips \"open up … please\"")
        check(SearchModel.webURL("go to youtube.com")?.absoluteString == "https://youtube.com", "\"go to youtube.com\" opens the site")
        check(SearchModel.webTerms("search the web for weather in vancouver") == "weather in vancouver", "web search drops \"search the web for\"")
        check(SearchModel.isQuestion("when is it due") && !SearchModel.isQuestion("open notes"), "tells questions from commands")
        let sums: [(String, String?)] = [("12*4.5", "54"), ("(3+4)/2", "3.5"), ("15% of 80", "12"), ("(12*4.5)+15% of 80", "66"), ("2^10", "1024"), ("-3 + 5", "2"),
                                         ("1/0", nil), ("2+", nil), ("open notes", nil), ("1.2.3+4", nil), ("((((1))))", nil), ("100", nil)]
        let sumsOK = sums.allSatisfy { q, want in Calculator.evaluate(q).map(Calculator.format) == want }
        check(sumsOK, "sums: " + sums.map { "\($0.0) = \(Calculator.evaluate($0.0).map(Calculator.format) ?? "-")" }.joined(separator: ", "))

        // Text tools
        let s = TextTools.sentences("Deep Blue won in 1997. It beat Kasparov. Dr. Smith said so. the end came fast.")
        check(s.count == 2 || s.count == 3, "sentences: \(s)")
        let blocks: [(text: String, group: Int, page: Int?)] = [
            ("Menu", 1, nil), ("Home", 1, nil),
            ("Programs that play games have been used to test AI techniques since the 1950s, and Deep Blue beat Kasparov in 1997.", 2, nil),
            (String(repeating: "This is a long sentence about something that goes on. ", count: 90), 3, nil),
        ]
        let passages = TextTools.passages(blocks)
        check(passages.first?.text == "Menu; Home" || passages.contains { $0.text.contains("Deep Blue") }, "passages merge tiny bits: \(passages.map { $0.text.prefix(30) })")
        check(passages.filter { $0.blocks == [3] }.count >= 3, "a 900-word block is split into pieces")
        check(TextTools.keywords("find my tax PDF from March") == ["tax", "pdf", "march"], "keywords: \(TextTools.keywords("find my tax PDF from March"))")

        // On-screen text: a web page splits a paragraph at every link; it's joined back.
        let el = AXUIElementCreateApplication(getpid())
        let screen = [
            ScreenText(text: "Menu", element: el, role: "AXStaticText", group: 1),
            ScreenText(text: "Deep Blue", element: el, role: "AXStaticText", group: 2),
            ScreenText(text: "became the first computer to beat a reigning world chess champion, Garry Kasparov, in 1997.", element: el, role: "AXStaticText", group: 2),
            ScreenText(text: "The rest of the page talks about other games that programs have learned to play since then.", element: el, role: "AXStaticText", group: 3),
        ]
        let (windowPassages, elements) = SearchModel.windowPassages(screen)
        check(windowPassages.first?.text.hasPrefix("Deep Blue became the first computer") == true && elements.count == 3,
              "a paragraph split by a link is joined: \"\(windowPassages.first?.text.prefix(40) ?? "")…\"")

        // Files, through Spotlight
        let hits = await files("jev typesafe meaning")
        check(!hits.isEmpty, "Spotlight found \(hits.count) files for \"jev typesafe meaning\"\(hits.first.map { ": \($0.name) in \($0.folder)" } ?? "")")
        let pdfs = await files("pdf")
        check(pdfs.allSatisfy { $0.kind.lowercased().contains("pdf") }, "\"pdf\" finds only PDFs (\(pdfs.count))")

        // PDFs: a made-up two-page document
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlf-selftest.pdf")
        makePDF(url, pages: handbook)
        guard let doc = PDFDocument(url: url) else { check(false, "made a test PDF"); return }
        let text = PDFReader.read(doc, url: url)
        check(text.passages.count >= 3, "PDF passages: \(text.passages.count)")
        check(text.passages.contains { $0.page == 2 && $0.text.contains("pet deposit") }, "the pet deposit is on page 3")

        // Text in pictures: a scanned PDF (each page only a picture of its text) and a picture file.
        let scanURL = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlf-selftest-scan.pdf")
        makeScannedPDF(scanURL, pages: handbook)
        let started = Date()
        guard let scanDoc = PDFDocument(url: scanURL) else { check(false, "made a scanned test PDF"); return }
        check((scanDoc.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the scanned PDF has no text of its own")
        let scan = PDFReader.read(scanDoc, url: scanURL)
        let scanMs = Int(Date().timeIntervalSince(started) * 1000)
        check(scan.picturePages == 3 && scan.skippedPages == 0, "Vision read \(scan.picturePages) scanned pages in \(scanMs) ms")
        let petPassage = scan.passages.first { $0.page == 2 && $0.text.lowercased().contains("pet deposit is 300") }
        check(petPassage != nil, "scanned page 3: \"\(scan.passages.first { $0.page == 2 }?.text.prefix(70) ?? "nothing")…\"")
        check(scan.passages.contains { $0.page == 1 && $0.text.contains("late fee of 50 dollars") }, "scanned page 2 reads the late fee")
        if let petPassage {
            let lines = petPassage.blocks.flatMap { scan.pictureLines[$0] ?? [] }
            // A sentence on the paragraph's first line only.
            let box = OCR.box(of: "Cats and small dogs are welcome with a signed pet agreement.", in: lines)
            let all = OCR.box(of: nil, in: lines)
            let bounds = scanDoc.page(at: 2)?.bounds(for: .mediaBox) ?? .zero
            check(box.map { bounds.contains($0) && $0.height < (all?.height ?? 0) } == true,
                  "a one-line sentence's box is on the page and smaller than its paragraph (\(box.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none"))")
        }

        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlf-selftest-note.png")
        if let image = textImage([handbook[1], "Parking. Each flat has one space in the garage. Visitors park on the street."]),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: pngURL)
        }
        let picture = await PDFReader.read(pngURL)
        check(PDFReader.isPicture(pngURL) && picture?.picturePages == 1, "a PNG is read as a one-page picture")
        let parking = picture?.passages.first { $0.text.contains("Parking") }
        check(parking != nil && !(parking?.text.contains("Rent is due") ?? true),
              "the picture's two paragraphs stay apart: \(picture?.passages.map { String($0.text.prefix(24)) } ?? [])")
        check(OCR.join([OCRLine(text: "the build-", box: .zero), OCRLine(text: "ing manager", box: .zero)]) == "the building manager",
              "a word broken across lines is joined")

        guard jev else { print("(Jev checks skipped: run with --jev and CTRLF_JEV_KEY)"); return }
        guard Settings.shared.jevKey != nil else { check(false, "CTRLF_JEV_KEY is set"); return }

        // Jev: search the PDF by meaning
        let lines = text.passages.enumerated().map { Line(id: "c\($0.offset + 1)", text: $0.element.text) }
        do {
            let r = try await Jev.shared.searchLines(lines, question: "how much do I pay to keep a dog?")
            let top = r.top.first.flatMap { Int($0.id.dropFirst()) }.map { text.passages[$0 - 1] }
            check(r.exists >= 0.5 && top?.page == 2, "PDF by meaning: page \((top?.page ?? -1) + 1), \(Int(r.exists * 100))% sure, \(r.ms) ms")
            if let top {
                let sentences = TextTools.sentences(top.text)
                let i = try await Jev.shared.pickSentence(sentences, question: "how much do I pay to keep a dog?")
                check(sentences[i].contains("300"), "the sentence: \"\(sentences[i])\"")
            }
            let scanLines = scan.passages.enumerated().map { Line(id: "c\($0.offset + 1)", text: $0.element.text) }
            let rs = try await Jev.shared.searchLines(scanLines, question: "how much do I pay to keep a dog?")
            let scanTop = rs.top.first.flatMap { Int($0.id.dropFirst()) }.map { scan.passages[$0 - 1] }
            check(rs.exists >= 0.5 && scanTop?.page == 2, "scanned PDF by meaning: page \((scanTop?.page ?? -1) + 1), \(Int(rs.exists * 100))% sure, \(rs.ms) ms")
            let none = try await Jev.shared.searchLines(lines, question: "what is the wifi password?")
            check(none.exists < 0.5, "a question the PDF can't answer says not found (\(Int(none.exists * 100))%)")
        } catch {
            check(false, "Jev PDF search: \(error.localizedDescription)")
        }

        // Jev: working out what a request means
        let cases: [(String, String, String?)] = [
            ("open safari", "open_app", "Safari"),
            ("launch the app I use for writing notes", "open_app", "Notes"),
            ("i want to do some maths", "open_app", "Calculator"),
            ("open whatsapp", "open_app", "WhatsApp"),
            ("put on some music on spotify", "open_app", "Spotify"),
            ("when did deep blue beat kasparov?", "find_in_window", nil),
            ("what does it say about the history of AI", "find_in_window", nil),
            ("summarize this", "find_in_window", nil),
            ("find the readme for the chrome extension", "open_file", nil),
            ("show me my screenshots", "find_files", nil),
            ("search the web for weather in vancouver", "web", nil),
            ("go to youtube.com", "web", nil),
        ]
        for (q, wantIntent, wantApp) in cases {
            let found = await files(q)
            let (state, questions) = SearchModel.routeRequest(q, front: "Google Chrome", title: "Artificial intelligence - Wikipedia", apps: apps, files: found)
            do {
                let a = try await Jev.shared.ask(state: state, questions: questions)
                let r = SearchModel.readRoute(a, apps: apps, files: found, question: SearchModel.isQuestion(q))
                let files = ["open_file", "find_files"]
                let intentOK = r.intent == wantIntent || (files.contains(wantIntent) && files.contains(r.intent))
                let appOK = wantApp == nil || r.app?.name == wantApp
                let detail = r.intent == "open_app" ? (r.app?.name ?? "?") : (r.fileOrder.first?.name ?? "")
                check(intentOK && appOK, "\"\(q)\" → \(r.intent) \(detail) (\(Int(r.intentSure * 100))%, \(r.ms) ms, \(found.count) files)")
            } catch {
                check(false, "\"\(q)\": \(error.localizedDescription)")
            }
        }
    }

    // MARK: Nemotron

    /// The Nemotron paths, against Nebius or the stand-in server. Routing answers are only
    /// checked for being right when it's the real Nebius; the stand-in just matches words.
    static func nemotron() async {
        let settings = Settings.shared
        guard settings.nebiusKey != nil else { check(false, "CTRLF_NEBIUS_KEY is set"); return }
        let live = settings.nebiusBase.host.map { !["127.0.0.1", "localhost"].contains($0) } ?? true
        print("Nebius at \(settings.nebiusBase.absoluteString)\(live ? "" : " (the stand-in)") · Jev key: \(settings.jevKey == nil ? "none" : "saved")")

        let status = await Nemotron.shared.status()
        check(status.ok && status.models.allSatisfy(\.1), "key check: \(status.detail) · \(status.models.map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: " "))")

        // The handbook PDF, found by meaning.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlf-selftest.pdf")
        makePDF(url, pages: handbook)
        guard let doc = PDFDocument(url: url) else { check(false, "made a test PDF"); return }
        let text = PDFReader.read(doc, url: url)
        let lines = text.passages.enumerated().map { Line(id: "c\($0.offset + 1)", text: $0.element.text) }
        let q = "how much is the pet deposit for a dog?"
        do {
            let r = try await Meaning.findLines(lines, question: q)
            let top = r.top.first.flatMap { Int($0.id.dropFirst()) }.map { text.passages[$0 - 1] }
            check(r.exists >= 0.5 && top?.page == 2,
                  "found by \(r.engine): page \((top?.page ?? -1) + 1), \(Int(r.exists * 100))% sure, \(r.ms) ms\(r.because.map { " · \($0)" } ?? "")")
            if settings.jevKey == nil { check(r.engine == "Lightning", "with no Jev key, Lightning does the finding") }
            if let top {
                let sentences = TextTools.sentences(top.text)
                let i = try await Meaning.pickSentence(sentences, question: q, engine: r.engine)
                check(sentences[i].contains("300"), "the sentence: \"\(sentences[i])\"")
                let a = try await Nemotron.shared.answer(question: q, excerpts: [top.text], source: "Tenant handbook.pdf")
                check(!a.text.isEmpty, "Nemotron 3 Super's answer (\(a.ms) ms): \(a.text)")
            }
            let none = try await Meaning.findLines(lines, question: "what is the wifi password?")
            check(none.exists < 0.5, "a question the PDF can't answer: not found (\(Int(none.exists * 100))%, \(none.engine))")
        } catch {
            check(false, "finding: \(Meaning.plain(error)) (\(error.localizedDescription))")
        }

        // Think harder.
        final class Phases { var seen: [String] = [] }
        let phases = Phases()
        do {
            let r = try await Nemotron.shared.thinkHarder(question: "what does living here cost besides the rent?", lines: lines,
                                                          source: "Tenant handbook.pdf") { phase, _ in
                if phases.seen.last != phase { phases.seen.append(phase) }
            }
            check(!r.answer.isEmpty && !r.lines.isEmpty,
                  "Nemotron 3 Ultra (\(r.reply.ms) ms, thought about \(r.reply.thoughtChars / 6) words, used \(r.lines.joined(separator: ", "))): \(r.answer)")
            check(phases.seen.first == "thinking" && phases.seen.last == "writing", "Ultra's progress: \(phases.seen.joined(separator: " → "))")
        } catch {
            check(false, "think harder: \(Meaning.plain(error)) (\(error.localizedDescription))")
        }

        // The bar's own logic on the handbook PDF: a search (finding, the sentence, Super's
        // answer), then think harder. The plan is switched to AI for this and put back after.
        let plan = settings.plan
        settings.plan = .ai
        let model = SearchModel()
        model.query = q
        model.askFile(url)
        var seen: [String] = []
        let first = await waitFor(model, seen: &seen) { $0.answer?.current?.sentence != nil && ($0.answer?.written != nil || $0.answer?.writeFailed != nil) }
        check(first?.current?.sentence?.contains("300") == true && first?.written != nil,
              "the bar: \(first?.engine ?? "nothing") found \(first?.place ?? "-"), sentence \"\(first?.current?.sentence ?? "-")\", \(first?.writtenBy ?? "no writer"): \(first?.written ?? first?.writeFailed ?? "-")")
        model.query = "what does living here cost besides the rent?"
        seen = []
        model.thinkHarder()
        let deep = await waitFor(model, seen: &seen, seconds: 30) { $0.answer?.engine == Tier.deep.short }
        check(deep?.written != nil && deep?.matches.isEmpty == false && deep?.showsSure == false,
              "⌘ Enter: \(deep?.writtenBy ?? "no answer") used \(deep?.matches.count ?? 0) part(s): \(deep?.written ?? "-")")
        check(seen.contains { $0.contains("nemotron 3 ultra · thinking") }, "while Ultra streams, the status line says so: \(seen.first { $0.contains("thinking") } ?? seen.joined(separator: " | "))")
        settings.plan = plan

        // Working out what a request means.
        let apps = AppIndex.all()
        let cases: [(String, String, String?)] = [
            ("open safari", "open_app", "Safari"),
            ("when is the rent due?", "find_in_window", nil),
            ("search the web for weather in vancouver", "web", nil),
        ]
        for (request, wantIntent, wantApp) in cases {
            let (state, questions) = SearchModel.routeRequest(request, front: "Preview", title: "Tenant handbook.pdf", apps: apps, files: [])
            do {
                let (answers, engine, because) = try await Meaning.ask(state: state, questions: questions)
                var r = SearchModel.readRoute(answers, apps: apps, files: [], question: SearchModel.isQuestion(request))
                r.engine = engine
                r.because = because
                let intents = ["open_app", "open_file", "find_files", "find_in_window", "web"]
                let ok = live ? r.intent == wantIntent && (wantApp == nil || r.app?.name == wantApp)
                              : intents.contains(r.intent) && (wantApp == nil || r.app?.name == wantApp)
                check(ok, "\"\(request)\" → \(r.intent) \(r.app?.name ?? "") (\(Int(r.intentSure * 100))%, \(r.took))")
            } catch {
                check(false, "\"\(request)\": \(Meaning.plain(error))")
            }
        }
    }

    /// Waits (up to `seconds`) for the bar's answer to pass `test`, noting each busy status seen.
    static func waitFor(_ model: SearchModel, seen: inout [String], seconds: Double = 20, _ test: (SearchModel) -> Bool) async -> Answer? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if case .busy(let text) = model.status, seen.last != text { seen.append(text) }
            if test(model) { return model.answer }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("  (timed out; status: \(model.status))")
        return model.answer
    }

    /// The made-up tenant handbook, one paragraph per page.
    static let handbook = [
        "Welcome to the tenant handbook. This handbook explains how the building works, who to call, and what to expect during your stay. Please read it carefully before moving in.",
        "Rent and payments. Rent is due on the first day of each month. A late fee of 50 dollars applies after the fifth. The building manager accepts payment by bank transfer only, and receipts are emailed within two days.",
        "Pets. Cats and small dogs are welcome with a signed pet agreement. The pet deposit is 300 dollars and is refunded when you move out if there is no damage.",
    ]

    static func files(_ q: String) async -> [FileHit] {
        await withCheckedContinuation { done in
            let search = FileSearch()
            search.run(q, limit: 40) { hits in
                _ = search
                done.resume(returning: hits)
            }
        }
    }

    /// A small PDF, one paragraph per page, for testing without real documents.
    static func makePDF(_ url: URL, pages: [String]) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// A picture of text: black on white, like a scanned page (1224×1584 px, twice US Letter).
    static func textImage(_ paragraphs: [String], width: Int = 1224, height: Int = 1584) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 36
        let attr = NSAttributedString(string: paragraphs.joined(separator: "\n"),
                                      attributes: [.font: NSFont(name: "Times New Roman", size: 30) ?? NSFont.systemFont(ofSize: 30),
                                                   .foregroundColor: NSColor.black, .paragraphStyle: style])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 140, dy: 140), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// A PDF whose pages are only pictures of their text, like a scan: no text to select.
    static func makeScannedPDF(_ url: URL, pages: [String]) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for text in pages {
            ctx.beginPDFPage(nil)
            if let image = textImage([text]) { ctx.draw(image, in: box) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: --route

    static func route(_ q: String, jev: Bool) async {
        let model = SearchModel()
        let found = await files(q)
        print("Spotlight: \(found.count) files")
        let rows = model.localRows(q)
        for r in rows.prefix(8) { print("  [\(r.tag)] \(r.title) — \(r.detail)") }
        guard jev else { return }
        let apps = AppIndex.all()
        let (state, questions) = SearchModel.routeRequest(q, front: "Google Chrome", title: nil, apps: apps, files: found)
        do {
            let (a, engine, because) = try await Meaning.ask(state: state, questions: questions)
            let r = SearchModel.readRoute(a, apps: apps, files: found)
            print("\(engine): \(r.intent) (\(Int(r.intentSure * 100))%) app: \(r.app?.name ?? "-") (\(Int(r.appSure * 100))%) file: \(r.fileOrder.first?.name ?? "-") (\(Int(r.fileSure * 100))%) in \(r.ms) ms\(because.map { " · \($0)" } ?? "")")
        } catch {
            print("Routing: \(Meaning.plain(error))")
        }
    }

    // MARK: --screen

    static func screen(_ name: String) async {
        print("screen reading allowed: \(ScreenShot.allowed)")
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            check(false, "\(name) is running")
            return
        }
        guard let shot = await ScreenShot.readWindow(pid: app.processIdentifier, frame: nil) else {
            check(false, "took a picture of \(name)'s window")
            return
        }
        check(!shot.blocks.isEmpty, "\(shot.blocks.count) blocks read from \(name)'s window in \(shot.ms) ms")
        for b in shot.blocks.prefix(8) {
            let box = b.dropFirst().reduce(b[0].box) { $0.union($1.box) }
            print("  [\(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))×\(Int(box.height))] \(OCR.join(b).prefix(80))")
        }
    }

    // MARK: --ocr

    static func ocr(_ url: URL) {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            check(false, "read \(url.path)")
            return
        }
        let size = CGSize(width: image.width, height: image.height)
        let lines = OCR.lines(in: image)
        func px(_ r: CGRect) -> String { "x \(Int(r.minX * size.width)) y \(Int(r.minY * size.height)) h \(Int(r.height * size.height))" }
        print("\(lines.count) lines in \(image.width)×\(image.height) px")
        for l in lines { print("  [\(px(l.box))] \(l.text)") }
        let blocks = OCR.blocks(lines, size: size)
        print("\(blocks.count) blocks")
        for b in blocks { print("  - \(OCR.join(b).prefix(90))") }
        // The same file the way the app reads it: as a one-page PDF.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let text = await PDFReader.read(url) {
                let page = text.document.page(at: 0)
                print("as a PDF page: bounds \(page?.bounds(for: .mediaBox) ?? .zero), \(text.passages.count) passages")
                for (n, lines) in text.pictureLines.sorted(by: { $0.key < $1.key }) {
                    print("  block \(n): \(lines.count) lines, first box \(lines.first?.box ?? .zero): \(OCR.join(lines).prefix(60))")
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: --pdf

    static func pdf(_ url: URL, _ question: String) async {
        guard let text = await PDFReader.read(url) else { check(false, "read \(url.path)"); return }
        print("\(text.passages.count) passages from \(text.document.pageCount) pages")
        let lines = text.passages.enumerated().map { Line(id: "c\($0.offset + 1)", text: $0.element.text) }
        do {
            let r = try await Meaning.findLines(lines, question: question)
            print("\(r.engine): \(Int(r.exists * 100))% sure, \(r.ms) ms, \(r.calls) call(s)\(r.because.map { " · \($0)" } ?? "")")
            for hit in r.top.prefix(3) {
                guard let i = Int(hit.id.dropFirst()) else { continue }
                let p = text.passages[i - 1]
                print("  page \((p.page ?? 0) + 1) (\(String(format: "%.3f", hit.score))): \(p.text.prefix(160))")
            }
        } catch {
            print("Finding: \(Meaning.plain(error))")
        }
    }

    // MARK: --icon: the app icon at every size macOS wants, for iconutil

    static func icon(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
            for scale in scales {
                let px = CGFloat(points * scale)
                // Apple's grid: the tile fills about 80% of the canvas, centred, with room for a shadow.
                let view = AppMark()
                    .frame(width: px * 0.8, height: px * 0.8)
                    .frame(width: px, height: px)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                guard let cg = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    check(false, "icon \(points)@\(scale)x")
                    continue
                }
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try? png.write(to: folder.appendingPathComponent(name))
            }
        }
        check(true, "icon set written")
    }

    // MARK: --render

    static func render(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = SearchModel()
        func save<V: View>(_ view: V, _ name: String) {
            let renderer = ImageRenderer(content: view.background(Theme.ground))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                check(false, "rendered \(name)")
                return
            }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
            check(true, "rendered \(name).png (\(Int(image.size.width))×\(Int(image.size.height)))")
        }
        save(SearchView(model: model, rendering: true), "bar-empty")

        model.query = "open the pdf about my tax return"
        let apps = AppIndex.all()
        let preview = apps.first { $0.name == "Preview" } ?? apps[0]
        let docs = URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        model.rows = [
            Row(kind: .file(FileHit(url: docs.appendingPathComponent("2025 Tax Return.pdf"), name: "2025 Tax Return.pdf", kind: "PDF document", modified: Date())),
                title: "2025 Tax Return.pdf", detail: "PDF document · ~/Documents/Taxes", jev: true),
            Row(kind: .file(FileHit(url: docs.appendingPathComponent("Tax receipts.pdf"), name: "Tax receipts.pdf", kind: "PDF document", modified: Date())),
                title: "Tax receipts.pdf", detail: "PDF document · ~/Documents/Taxes"),
            Row(kind: .app(preview), title: preview.name, detail: preview.url.deletingLastPathComponent().path),
            Row(kind: .window, title: "find “open the pdf about my tax return” in Google Chrome", detail: "search what's on screen by meaning"),
            Row(kind: .web, title: "search the web for “open the pdf about my tax return”", detail: "opens your browser"),
        ]
        model.selected = 0
        model.status = .ok("open 2025 Tax Return.pdf", "94% sure · 312 ms")
        save(SearchView(model: model, rendering: true), "bar-results")

        // Jev picking an app from plain English, as on the download page.
        model.query = "i want to do some maths"
        let calculator = apps.first { $0.name == "Calculator" } ?? apps[0]
        model.rows = [
            Row(kind: .app(calculator), title: calculator.name, detail: calculator.url.deletingLastPathComponent().path, jev: true),
            Row(kind: .window, title: "find “i want to do some maths” in Safari", detail: "search what's on screen by meaning"),
            Row(kind: .web, title: "search the web for “i want to do some maths”", detail: "opens your browser"),
        ]
        model.selected = 0
        model.status = .ok("open Calculator", "96% sure · 136 ms")
        save(SearchView(model: model, rendering: true), "bar-app")

        model.query = "how much is the pet deposit?"
        let passage = TextTools.Passage(text: "Pets. Cats and small dogs are welcome with a signed pet agreement. The pet deposit is 300 dollars and is refunded when you move out if there is no damage.", blocks: [2], page: 2)
        model.answer = Answer(question: model.query, source: "Preview · Tenant handbook.pdf", appName: "Preview",
                              matches: [Match(passage: passage, score: 0.9, sentence: "The pet deposit is 300 dollars and is refunded when you move out if there is no damage.", element: nil),
                                        Match(passage: passage, score: 0.1, sentence: nil, element: nil)],
                              pdf: nil, sure: 0.97, ms: 284, usedJev: true, arrived: .distantPast)
        model.status = .ok("97% sure Preview answers it", "1 of 2 · Jev · 284 ms")
        save(SearchView(model: model, rendering: true), "bar-answer")

        // With Nemotron: Super's written answer above the sentence, then Ultra after ⌘ Enter.
        model.answer?.engine = "Jev"
        model.answer?.written = "The pet deposit is 300 dollars. You get it back when you move out, as long as there's no damage."
        model.answer?.writtenBy = "nemotron 3 super · 0.9 s"
        save(SearchView(model: model, rendering: true), "bar-answer-nemotron")
        let rent = TextTools.Passage(text: "Rent and payments. Rent is due on the first day of each month. A late fee of 50 dollars applies after the fifth.", blocks: [1], page: 1)
        model.query = "what does living here cost besides the rent?"
        model.answer = Answer(question: model.query, source: "Preview · Tenant handbook.pdf", appName: "Preview",
                              matches: [Match(passage: passage, score: 1, sentence: "The pet deposit is 300 dollars and is refunded when you move out if there is no damage.", element: nil),
                                        Match(passage: rent, score: 1, sentence: nil, element: nil)],
                              pdf: nil, sure: 1, ms: 8200, usedJev: true, arrived: .distantPast, engine: "Ultra",
                              written: "Besides rent, there's a 50 dollar late fee if rent is paid after the fifth, and a 300 dollar pet deposit if you keep a cat or small dog. The deposit is refunded if there's no damage.",
                              writtenBy: "nemotron 3 ultra · 8.2 s · thought 1,240 words")
        model.status = .ok("ultra used this part of Preview", "1 of 2 · Ultra · 8.2 s")
        save(SearchView(model: model, rendering: true), "bar-ultra")
        model.answer = nil
        model.query = "how much is the pet deposit?"
        model.answer = Answer(question: model.query, source: "Preview · Tenant handbook.pdf", appName: "Preview",
                              matches: [Match(passage: passage, score: 0.9, sentence: "The pet deposit is 300 dollars and is refunded when you move out if there is no damage.", element: nil),
                                        Match(passage: passage, score: 0.1, sentence: nil, element: nil)],
                              pdf: nil, sure: 0.97, ms: 284, usedJev: true, arrived: .distantPast)

        let answer = model.answer
        model.answer = nil
        model.needsPermission = true
        model.status = .error("Pareto needs permission to read the front window.")
        save(SearchView(model: model, rendering: true), "bar-permission")

        save(SettingsView(welcome: true, glass: false, rendering: true), "settings-welcome")

        // The same in the other look, then the look the user picked is put back.
        let picked = Settings.shared.look
        Settings.shared.look = picked == .digital ? .terminal : .digital
        model.needsPermission = false
        model.answer = answer
        model.status = .ok("97% sure Preview answers it", "1 of 2 · 284 ms")
        save(SearchView(model: model, rendering: true), "bar-answer-\(Settings.shared.look.rawValue)")
        save(SettingsView(welcome: true, glass: false, rendering: true), "settings-\(Settings.shared.look.rawValue)")
        Settings.shared.look = picked
    }

    /// The welcome window as a real window draws it, switches and key box included (which
    /// ImageRenderer can't draw), for the pictures in READ ME FIRST: the AI plan chosen, no key
    /// typed, and neither kind of screen reading allowed yet. The user's own plan and look are
    /// put back afterwards.
    static func renderGuide(to folder: URL) async {
        let settings = Settings.shared
        let (plan, look) = (settings.plan, settings.look)
        settings.plan = .ai
        settings.look = .digital
        let state = SettingsState()
        state.trusted = false
        state.screenAllowed = false
        let host = NSHostingView(rootView: SettingsView(welcome: true, state: state, rendering: true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: host.frame.width, height: host.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = NSColor(hex: 0xE9E9E5)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("welcome-window.png"))
                check(true, "rendered welcome-window.png (\(Int(host.bounds.width))×\(Int(host.bounds.height)))")
            } else { check(false, "rendered welcome-window.png") }
        } else { check(false, "rendered welcome-window.png") }
        window.orderOut(nil)
        settings.plan = plan
        settings.look = look
    }
}
