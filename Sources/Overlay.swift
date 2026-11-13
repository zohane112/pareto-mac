// Showing an answer: an outline drawn over another app's window for a few seconds, and a PDF
// viewer that opens at the right page with the answer marked.

import AppKit
import PDFKit
import SwiftUI

/// A click-through window that outlines a spot on screen, then fades.
final class GlowOverlay {
    static let shared = GlowOverlay()
    private var window: NSWindow?
    private var fade: DispatchWorkItem?

    /// `rect` is in Accessibility coordinates: points from the top-left of the main screen.
    func show(_ rect: CGRect, for seconds: TimeInterval = 3) {
        guard let main = NSScreen.screens.first else { return }
        let flipped = CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let frame = flipped.insetBy(dx: -8, dy: -6)
        hide()
        let w = NSWindow(contentRect: frame.insetBy(dx: -20, dy: -20), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.contentView = NSHostingView(rootView: GlowBox().padding(20))
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; w.animator().alphaValue = 1 }
        window = w
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide(animated: Bool = false) {
        fade?.cancel()
        guard let w = window else { return }
        window = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) })
        } else {
            w.orderOut(nil)
        }
    }
}

/// A black outline (white in the terminal look) with the red dot on its corner, over any app.
private struct GlowBox: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.digital ? Color(hex: 0x0C0C0C) : Color(hex: 0xE8E8E3), lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0C0C0C, opacity: Theme.digital ? 0.06 : 0.12)))
            .overlay(Circle().fill(Theme.signal).frame(width: 9, height: 9).offset(x: -4, y: -4), alignment: .topLeading)
            .shadow(color: .black.opacity(0.25), radius: 6)
    }
}

/// Our own PDF window: opens a PDF at a page with the answer selected. Used for PDFs shown
/// in any app, since most PDF apps can't be told to go to a page.
final class PDFWindow: NSObject, NSWindowDelegate {
    static var open: [PDFWindow] = []
    private let window: NSWindow
    var contentView: NSView? { window.contentView }
    private let view = PDFView()

    /// `box` is where the answer is on its page, in page points, when the page was read from
    /// its picture (a scan, or a picture file) and has no text to find.
    static func show(_ document: PDFDocument, url: URL, page: Int, sentence: String?, box: CGRect? = nil) {
        let w = PDFWindow(document: document, url: url)
        open.append(w)
        w.go(page: page, sentence: sentence, box: box)
    }

    private init(document: PDFDocument, url: URL) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.representedURL = url.isFileURL ? url : nil
        window.isReleasedWhenClosed = false
        window.delegate = self
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = Theme.digital ? NSColor(hex: 0xE9E9E5) : NSColor(hex: 0x0A0A0A)
        window.contentView = view
        window.center()
    }

    private func go(page: Int, sentence: String?, box: CGRect?) {
        guard let doc = view.document, let pdfPage = doc.page(at: min(page, doc.pageCount - 1)) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        view.go(to: pdfPage)
        if let box, box.width > 1, box.height > 1 {
            // A page read from its picture: mark the answer with a highlight drawn over it. The
            // mark is only in this window; the file isn't changed.
            let mark = PDFAnnotation(bounds: box.insetBy(dx: -3, dy: -2), forType: .highlight, withProperties: nil)
            mark.color = NSColor(hex: 0x0C0C0C).withAlphaComponent(0.22)
            pdfPage.addAnnotation(mark)
            view.go(to: box.insetBy(dx: 0, dy: -120), on: pdfPage)
            return
        }
        guard let sentence, !sentence.isEmpty else { return }
        // Find the answer on its page: first the whole sentence, then its opening words,
        // since PDF text often breaks lines differently.
        let tries = [sentence, String(sentence.prefix(80)), String(sentence.prefix(40))]
        for text in tries {
            let hits = doc.findString(text.trimmingCharacters(in: .whitespaces), withOptions: [.caseInsensitive])
            if let hit = hits.first(where: { $0.pages.contains(pdfPage) }) ?? hits.first {
                hit.color = NSColor(hex: 0x0C0C0C).withAlphaComponent(0.22)
                view.highlightedSelections = [hit]
                view.setCurrentSelection(hit, animate: true)
                view.go(to: hit)
                return
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        PDFWindow.open.removeAll { $0 === self }
    }
}
