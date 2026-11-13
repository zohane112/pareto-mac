// The app: a menu bar icon, the global shortcut, the bar itself and the settings window.
// It has no Dock icon; it lives in the menu bar like Spotlight's helpers.

import AppKit
import Combine
import SwiftUI

/// The bar's window: borderless and see-through, so the panel's rounded corners and shadow show.
final class BarPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCommand: ((String) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 788, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(),
           onCommand?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A borderless window that can still take typing, for settings.
final class TerminalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SearchModel()
    private var panel: BarPanel!
    private var host: NSHostingView<SearchView>!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?
    private var watchers: Set<AnyCancellable> = []
    private var topEdge: CGFloat = 0
    private var keyDown = false
    private var visibleAtPress = false
    private var holdTimer: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if offerMoveToApplications() { return }
        quitOlderCopies()
        retireOldName()
        buildPanel()
        buildMenuBarIcon()
        registerHotKey()
        Settings.shared.$shortcut.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerHotKey() }
        }.store(in: &watchers)
        // Windows follow the look: light controls for digital, dark for terminal.
        Settings.shared.$look.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.settingsWindow?.appearance = Theme.appearance
                self?.panel.appearance = Theme.appearance
            }
        }.store(in: &watchers)
        // Refit the settings window when a key is saved or removed.
        Settings.shared.$plan.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitSettings() }
        }.store(in: &watchers)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        if !Settings.shared.onboarded {
            Settings.shared.onboarded = true
            // A bar you reach with a shortcut should be there after a restart too. It's a
            // switch in the welcome window, and only set for the copy in Applications.
            if Bundle.main.bundlePath.hasPrefix("/Applications/") { Settings.shared.launchAtLogin = true }
            showSettings(welcome: true)
        }
    }

    /// Opened straight from the download (a disk image) or from Downloads without moving it,
    /// macOS runs the app from a temporary copy, and its permissions and "open when I log in"
    /// wouldn't stick. Offers to put it in Applications and reopen it from there. Returns true
    /// when this copy is about to quit.
    private func offerMoveToApplications() -> Bool {
        let here = Bundle.main.bundleURL
        guard here.path.hasPrefix("/Volumes/") || here.path.contains("/AppTranslocation/") else { return false }
        let alert = NSAlert()
        alert.messageText = "Move Pareto to Applications?"
        alert.informativeText = "It's running from the download. From Applications, it keeps its permissions and opens when you log in."
        alert.addButton(withTitle: "Move and Open")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(here.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                // An older version goes to the Trash, and stops if it's running.
                for old in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                where old != NSRunningApplication.current { old.terminate() }
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: here, to: target)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move it"
            failed.informativeText = "Drag Pareto onto the Applications folder in the download window, then open it from Applications."
            failed.runModal()
            return false
        }
        NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// A new version opened while an older one is still running: the older one quits, so they
    /// don't fight over the shortcut.
    private func quitOlderCopies() {
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other != NSRunningApplication.current {
            other.terminate()
        }
    }

    /// Before 1.3.0 the app was called "Ctrl+F by meaning". A copy still in Applications under
    /// that name would also open at login and fight over the shortcut, so this offers once to
    /// put it in the Trash. Only a copy with this app's own identifier is touched.
    private func retireOldName() {
        let old = URL(fileURLWithPath: "/Applications/Ctrl+F by meaning.app")
        guard old.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL,
              !UserDefaults.standard.bool(forKey: "keptOldCopy"),
              Bundle(url: old)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        let alert = NSAlert()
        alert.messageText = "Move the old copy to the Trash?"
        alert.informativeText = "Pareto used to be called Ctrl+F by meaning. That older copy is still in Applications, and it would fight Pareto for the shortcut. Your key and settings stay."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: "keptOldCopy")
            return
        }
        try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder or Launchpad shows the bar.
        showBar()
        return false
    }

    // MARK: The bar

    private func buildPanel() {
        panel = BarPanel()
        host = NSHostingView(rootView: SearchView(model: model))
        panel.contentView = host
        panel.onResignKey = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            // Clicking somewhere else closes the bar, like Spotlight.
            DispatchQueue.main.async { if !(self.panel.isKeyWindow) { self.hideBar(restoreFront: false) } }
        }
        panel.onCommand = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "c":
                if self.model.answer != nil, (self.panel.firstResponder as? NSTextView)?.selectedRange().length ?? 0 == 0 {
                    self.model.copyAnswer()
                    return true
                }
                return false
            case ",":
                self.hideBar(restoreFront: false)
                self.showSettings(welcome: false)
                return true
            default:
                return false
            }
        }
        model.close = { [weak self] restore in self?.hideBar(restoreFront: restore) }
        // The bar grows and shrinks with its content, keeping its top edge still.
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanel() }
        }.store(in: &watchers)
    }

    private func fitPanel() {
        guard panel.isVisible else { return }
        let size = host.fittingSize
        var frame = panel.frame
        frame.size = size
        frame.origin.y = topEdge - size.height
        panel.setFrame(frame, display: true)
    }

    func toggleBar() {
        panel.isVisible ? hideBar(restoreFront: true) : showBar()
    }

    // MARK: The shortcut: tap to open or close, hold to speak

    private func shortcutPressed() {
        guard !keyDown else { return } // a held key can repeat
        keyDown = true
        visibleAtPress = panel.isVisible
        guard Settings.shared.holdToTalk else { toggleBar(); return }
        if !panel.isVisible { showBar() }
        holdTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.keyDown else { return }
            self.startListening()
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func shortcutReleased() {
        keyDown = false
        holdTimer?.cancel()
        guard Settings.shared.holdToTalk else { return }
        if model.listening {
            stopListening()
        } else if visibleAtPress {
            hideBar(restoreFront: true)
        }
    }

    private func startListening() {
        Voice.shared.authorize { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.model.status = .error(Voice.Problem.noPermission.rawValue)
                return
            }
            // The first time, macOS asks for permission while the key is held; start only if it still is.
            guard self.keyDown, self.panel.isVisible else { return }
            if let problem = Voice.shared.start() {
                self.model.status = .error(problem.rawValue)
                return
            }
            self.model.listening = true
            self.model.query = ""
            Voice.shared.onPartial = { [weak self] text in self?.model.query = text }
        }
    }

    private func stopListening() {
        Voice.shared.stop { [weak self] text in
            guard let self else { return }
            self.model.listening = false
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty {
                self.model.status = .miss("didn't catch that", "hold the shortcut and speak")
            } else {
                self.model.queryChanged(said, burst: true, spoken: true)
            }
        }
    }

    func showBar(query: String? = nil) {
        let front = NSWorkspace.shared.frontmostApplication
        model.prepare(front: front)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = host.fittingSize
        let visible = screen.visibleFrame
        topEdge = visible.maxY - visible.height * 0.16 + 34
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: topEdge - size.height, width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusField()
        if let query, !query.isEmpty {
            model.queryChanged(query, burst: true)
        }
    }

    func hideBar(restoreFront: Bool) {
        guard panel.isVisible else { return }
        if Voice.shared.listening { Voice.shared.cancel() }
        model.listening = false
        panel.orderOut(nil)
        if restoreFront, let app = model.front { app.activate() }
    }

    private func focusField() {
        func find(_ view: NSView) -> NSTextField? {
            if let f = view as? FocusField { return f }
            for sub in view.subviews { if let f = find(sub) { return f } }
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = find(self.host) else { return }
            self.panel.makeFirstResponder(field)
        }
    }

    private func registerHotKey() {
        let s = Settings.shared.shortcut
        hotKey = nil
        hotKey = HotKey(keyCode: s.keyCode, modifiers: s.modifiers,
                        pressed: { [weak self] in Task { @MainActor in self?.shortcutPressed() } },
                        released: { [weak self] in Task { @MainActor in self?.shortcutReleased() } })
        Settings.shared.shortcutTaken = hotKey == nil
        updateMenu()
    }

    // MARK: Menu bar

    private func buildMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Pareto")
            button.image?.isTemplate = true
        }
        updateMenu()
    }

    private func updateMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open the bar  (\(Settings.shared.shortcut.label))", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if hotKey == nil {
            let warn = NSMenuItem(title: "That shortcut is taken; pick another in Settings", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pareto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func menuOpen() { showBar() }
    @objc private func menuSettings() { showSettings(welcome: false) }

    // MARK: Settings

    func showSettings(welcome: Bool) {
        if let w = settingsWindow {
            w.contentView = NSHostingView(rootView: SettingsView(welcome: welcome))
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = NSHostingView(rootView: SettingsView(welcome: welcome))
        let w = TerminalWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                               styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = Theme.appearance
        w.contentView = view
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func fitSettings() {
        guard let w = settingsWindow, let view = w.contentView else { return }
        let size = view.fittingSize
        var frame = w.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        w.setFrame(frame, display: true, animate: true)
    }

    // MARK: Links: ctrlf-meaning://open?q=...

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: string) else { return }
        let testing = ProcessInfo.processInfo.environment["CTRLF_TEST"] == "1"
        switch url.host {
        case "open":
            // Opens the bar with the text in it. A link never runs anything by itself: any web
            // page can offer one, so running waits for the person's Enter.
            showBar()
            if let q = url.queryItems?.first(where: { $0.name == "q" })?.value, !q.isEmpty {
                model.queryChanged(q, burst: testing)
            }
        case "settings":
            showSettings(welcome: false)
        case _ where !testing:
            // Everything below is for the checks only (the app started with CTRLF_TEST=1).
            showBar()
        case "show":
            model.showAnswer()
        case "type":
            // For testing: as if typed, not spoken.
            if !panel.isVisible { showBar() }
            model.queryChanged(url.queryItems?.first { $0.name == "q" }?.value ?? "", burst: false)
        case "enter":
            model.submit()
        case "askpicture":
            // For testing: ask the picture of the front window, skipping its text.
            if !panel.isVisible { showBar() }
            model.query = url.queryItems?.first { $0.name == "q" }?.value ?? ""
            model.searchPictureOnly()
        case "readself":
            // For testing the window reader on this app's own settings window.
            let path = url.queryItems?.first { $0.name == "path" }?.value ?? NSTemporaryDirectory() + "ctrlf-read.txt"
            showSettings(welcome: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let me = NSRunningApplication.current
                let content = WindowReader.read(me)
                let (passages, _) = SearchModel.windowPassages(content?.texts ?? [])
                let report = "trusted: \(WindowReader.trusted)\ntexts: \(content?.texts.count ?? -1)\nms: \(content?.ms ?? -1)\n"
                    + passages.map { "- " + $0.text }.joined(separator: "\n")
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
            }
        case "ask":
            // Ask about a PDF: ctrlf-meaning://ask?path=/file.pdf&q=question
            guard let path = url.queryItems?.first(where: { $0.name == "path" })?.value else { return }
            showBar()
            model.query = url.queryItems?.first { $0.name == "q" }?.value ?? ""
            model.askFile(URL(fileURLWithPath: path))
        case "snapshot":
            // For testing: saves a picture of the bar (or the settings window) as it is now.
            let path = url.queryItems?.first { $0.name == "path" }?.value ?? NSTemporaryDirectory() + "ctrlf-bar.png"
            let which = url.queryItems?.first { $0.name == "window" }?.value
            let view: NSView? = which == "settings" ? settingsWindow?.contentView
                : which == "pdf" ? PDFWindow.open.last?.contentView : host
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        default:
            showBar()
        }
    }
}
