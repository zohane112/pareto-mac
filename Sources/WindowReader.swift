// Reading the front window, only when the bar is opened, never kept. It uses macOS
// Accessibility, which needs the user's one-time permission. Password fields are never read.
// A window showing a PDF or a picture file is read from the file itself, which is faster and
// more complete; Chrome showing a PDF counts too.

import AppKit
import ApplicationServices
import PDFKit

/// A piece of on-screen text, and where it is, so it can be highlighted later.
struct ScreenText {
    let text: String
    let element: AXUIElement
    let role: String
    let group: Int
}

struct WindowContent {
    let appName: String
    let bundleID: String?
    let pid: pid_t
    let title: String
    let texts: [ScreenText]
    /// The PDF or picture file the window shows, read from the file instead.
    let file: URL?
    /// Where the window is on screen, in points from the top-left.
    let frame: CGRect?
    let ms: Int
}

enum WindowReader {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt to allow Pareto in Accessibility settings.
    static func askForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    /// An attribute that should hold another element, checked rather than assumed: apps
    /// sometimes answer with something else.
    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attr(el, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attr(el, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    /// Roles whose text belongs to the block around them (runs of text inside a paragraph).
    private static let inline: Set<String> = ["AXStaticText", "AXLink"]
    /// Parts of a window that are never the answer: menus, toolbars, scroll bars, pictures.
    private static let skipped: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar", "AXImage",
                                               "AXToolbar", "AXSecureTextField", "AXValueIndicator", "AXIncrementor"]

    /// Reads the text of `app`'s front window. Stops after `budget` seconds or `maxNodes`
    /// elements, so a huge page can't hang the bar.
    static func read(_ app: NSRunningApplication, budget: TimeInterval = 4, maxNodes: Int = 40000) -> WindowContent? {
        let started = Date()
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        // Chrome, Edge, Slack, Discord and other Chromium apps only share page text once asked.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let window = element(appEl, kAXFocusedWindowAttribute) ?? element(appEl, kAXMainWindowAttribute) else { return nil }
        let title = string(window, kAXTitleAttribute) ?? ""
        var file = fileURL(window: window)
        let frame = Self.frame(of: window)

        var texts: [ScreenText] = []
        var nodes = 0
        var groupCounter = 0
        var deadline = budget
        // Depth-first in reading order. Each block-level element starts a new group, so runs
        // of text inside one paragraph can be joined back together.
        func visit(_ el: AXUIElement, group: Int, depth: Int) {
            guard nodes < maxNodes, depth < 60, Date().timeIntervalSince(started) < deadline else { return }
            nodes += 1
            // One round trip to the app for everything needed about this element.
            let info = batch(el)
            let role = info.role
            let subrole = info.subrole
            if skipped.contains(role) || subrole == "AXSecureTextField" { return }
            let myGroup: Int
            if inline.contains(role) {
                myGroup = group
            } else {
                groupCounter += 1
                myGroup = groupCounter
            }
            switch role {
            case "AXStaticText":
                let value = info.value ?? info.description ?? ""
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { texts.append(ScreenText(text: text, element: el, role: role, group: myGroup)) }
            case "AXTextArea":
                // A whole document (Notes, TextEdit, Mail's reply) is one text area: each of its
                // paragraphs becomes its own piece, all pointing at the same element.
                let value = info.value ?? ""
                for para in value.components(separatedBy: .newlines) {
                    let text = para.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    groupCounter += 1
                    texts.append(ScreenText(text: text, element: el, role: role, group: groupCounter))
                }
                return // its children repeat the text
            case "AXTextField", "AXSearchField", "AXComboBox":
                return // one-line boxes: search fields, forms, the address bar; never read
            case "AXWebArea":
                // A browser tab showing a PDF: read the PDF itself (arXiv's addresses end in /pdf/…).
                if file == nil, let url = attr(el, "AXURL") as? URL, url.scheme?.hasPrefix("http") == true || url.isFileURL,
                   url.pathExtension.lowercased() == "pdf" || url.path.contains("/pdf/") {
                    file = url
                }
            default:
                break
            }
            for child in info.children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                visit(child as! AXUIElement, group: myGroup, depth: depth + 1)
            }
        }
        visit(window, group: 0, depth: 0)
        // Chrome and Electron apps build their page text a moment after being asked for it:
        // a nearly empty first read gets one more try.
        if texts.count < 5, file == nil, Date().timeIntervalSince(started) < budget {
            Thread.sleep(forTimeInterval: 0.35)
            texts = []
            nodes = 0
            groupCounter = 0
            deadline = budget + 0.8
            visit(window, group: 0, depth: 0)
        }

        return WindowContent(appName: app.localizedName ?? "this app", bundleID: app.bundleIdentifier,
                             pid: app.processIdentifier, title: title, texts: texts, file: file, frame: frame,
                             ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    private struct ElementInfo {
        var role = ""
        var subrole = ""
        var value: String?
        var description: String?
        var children: [AnyObject] = []
    }

    private static let batchNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute,
                                     kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray

    /// Role, subrole, value, description and children in one request. An attribute the element
    /// doesn't have comes back as an error value, which is simply skipped.
    private static func batch(_ el: AXUIElement) -> ElementInfo {
        var values: CFArray?
        var info = ElementInfo()
        guard AXUIElementCopyMultipleAttributeValues(el, batchNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == 5 else {
            // Fall back to asking one at a time.
            info.role = string(el, kAXRoleAttribute) ?? ""
            info.subrole = string(el, kAXSubroleAttribute) ?? ""
            info.value = attr(el, kAXValueAttribute) as? String
            info.description = string(el, kAXDescriptionAttribute)
            info.children = attr(el, kAXChildrenAttribute) as? [AnyObject] ?? []
            return info
        }
        info.role = array[0] as? String ?? ""
        info.subrole = array[1] as? String ?? ""
        info.value = array[2] as? String
        info.description = array[3] as? String
        info.children = array[4] as? [AnyObject] ?? []
        return info
    }

    /// Just the front window's title, quickly (one question to the app).
    static func title(of app: NSRunningApplication) -> String? {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        guard let window = element(appEl, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    /// The PDF or picture file a window is showing, if any: Preview, Acrobat, Skim and others
    /// say which file their window has open.
    private static func fileURL(window: AXUIElement) -> URL? {
        if let doc = string(window, kAXDocumentAttribute), let url = URL(string: doc), PDFReader.canRead(url) {
            return url
        }
        if let url = attr(window, "AXURL") as? URL, PDFReader.canRead(url) { return url }
        return nil
    }

    // MARK: - Showing the answer in the window

    /// Scrolls the element into view and, when it's editable text, selects the answer so the
    /// app itself highlights it. Returns where it is on screen, for the glow overlay.
    static func reveal(_ element: AXUIElement, sentence: String?, passage: String? = nil) -> CGRect? {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        let role = string(element, kAXRoleAttribute) ?? ""
        // A text area: select the sentence (the app highlights and scrolls to it), and outline
        // just that sentence. Positions are counted in UTF-16, as macOS counts them.
        if role == "AXTextArea", let value = attr(element, kAXValueAttribute) as? String,
           let target = [sentence, passage].compactMap({ $0 }).first,
           let range = value.range(of: String(target.prefix(80)), options: [.caseInsensitive]) {
            let start = value.utf16.distance(from: value.utf16.startIndex, to: range.lowerBound.samePosition(in: value.utf16) ?? value.utf16.startIndex)
            let length = min(target.utf16.count, value.utf16.count - start)
            var cf = CFRange(location: start, length: max(0, length))
            if let axRange = AXValueCreate(.cfRange, &cf) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                var bounds: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &bounds) == .success,
                   let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
                    if rect.width > 2, rect.height > 2 { return rect }
                }
            }
        }
        return frame(of: element)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let posRef = axValue(element, kAXPositionAttribute), let sizeRef = axValue(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef, .cgPoint, &point)
        AXValueGetValue(sizeRef, .cgSize, &size)
        guard size.width > 2, size.height > 2 else { return nil }
        return CGRect(origin: point, size: size)
    }
}

// MARK: - PDFs

struct PDFText {
    let url: URL
    let document: PDFDocument
    let passages: [TextTools.Passage]
    /// Blocks read from a page's picture (a scan, or an image file): their lines, with boxes
    /// in page points, so the answer can be highlighted. Keyed by block number.
    var pictureLines: [Int: [OCRLine]] = [:]
    /// How many pages were read from their picture, and how many were left out for time.
    var picturePages = 0
    var skippedPages = 0
}

enum PDFReader {
    /// Picture files that can be asked about like a one-page PDF.
    static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func isPicture(_ url: URL) -> Bool { pictureTypes.contains(url.pathExtension.lowercased()) }
    static func canRead(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" || isPicture(url) }

    /// Reads every page's text and cuts it into passages, each knowing its page. A picture file
    /// becomes a one-page PDF, read with Vision.
    static func read(_ url: URL) async -> PDFText? {
        var document: PDFDocument?
        if url.isFileURL, isPicture(url) {
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                let doc = PDFDocument()
                doc.insert(page, at: 0)
                document = doc
            }
        } else if url.isFileURL {
            document = PDFDocument(url: url)
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            document = PDFDocument(data: data)
        }
        guard let document else { return nil }
        return read(document, url: url)
    }

    static func read(_ document: PDFDocument, url: URL, pictureSeconds: TimeInterval = 20) -> PDFText {
        let count = min(document.pageCount, 600)
        var perPage = [[(text: String, lines: [OCRLine]?)]](repeating: [], count: count)
        var pictured: [Int] = []
        for i in 0..<count {
            guard let page = document.page(at: i) else { continue }
            let text = page.string ?? ""
            if text.filter({ !$0.isWhitespace }).count < 20 {
                pictured.append(i)
            } else {
                perPage[i] = paragraphs(text).map { ($0, nil) }
            }
        }

        // Pages with almost no text are pictures, like a scan: Vision reads them, several at
        // once. PDFKit draws one page at a time, so drawing is taken in turns.
        var skipped = max(0, pictured.count - 200)
        var read = 0
        if !pictured.isEmpty {
            let todo = Array(pictured.prefix(200))
            let deadline = Date().addingTimeInterval(pictureSeconds)
            let lock = NSLock()
            func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
            var results: [Int: [[OCRLine]]] = [:]
            var late = 0
            DispatchQueue.concurrentPerform(iterations: todo.count) { k in
                let i = todo[k]
                guard Date() < deadline else { locked { late += 1 }; return }
                let (image, bounds, turned): (CGImage?, CGRect, Bool) = locked {
                    let page = document.page(at: i)
                    return (page.flatMap(OCR.image(of:)), page?.bounds(for: .mediaBox) ?? .zero, (page?.rotation ?? 0) != 0)
                }
                guard let image else { return }
                let found = OCR.lines(in: image)
                let blocks = OCR.blocks(found, size: CGSize(width: image.width, height: image.height)).map { lines in
                    lines.map { line -> OCRLine in
                        var line = line
                        // Page points from the page's bottom-left, as PDFKit counts them. A
                        // turned page gets no box: its picture is drawn turned.
                        line.box = turned ? .zero : CGRect(x: bounds.minX + line.box.minX * bounds.width,
                                                           y: bounds.minY + (1 - line.box.maxY) * bounds.height,
                                                           width: line.box.width * bounds.width,
                                                           height: line.box.height * bounds.height)
                        return line
                    }
                }
                locked { results[i] = blocks }
            }
            for (i, blocks) in results { perPage[i] = blocks.map { (OCR.join($0), $0) } }
            read = results.count
            skipped += late
        }

        var blocks: [(text: String, group: Int, page: Int?)] = []
        var pictureLines: [Int: [OCRLine]] = [:]
        for (i, page) in perPage.enumerated() {
            for block in page {
                if let lines = block.lines { pictureLines[blocks.count] = lines }
                blocks.append((block.text, i, i))
            }
        }
        return PDFText(url: url, document: document, passages: TextTools.passages(blocks),
                       pictureLines: pictureLines, picturePages: read, skippedPages: skipped)
    }

    /// A page's text → paragraphs: blank lines, or a line ending a sentence followed by a new
    /// line. Hard-wrapped lines inside a paragraph are joined.
    static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .flatMap { para -> [String] in
                var out: [String] = []
                var current = ""
                for line in para.components(separatedBy: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.isEmpty { continue }
                    current += current.isEmpty ? l : (current.hasSuffix("-") ? String(current.dropLast()) + l : " " + l)
                    if l.hasSuffix(".") || l.hasSuffix(":") || l.hasSuffix("?") || l.hasSuffix("!"),
                       TextTools.words(current) > 25 {
                        out.append(current)
                        current = ""
                    }
                }
                if !current.isEmpty { out.append(current) }
                return out
            }
    }
}
