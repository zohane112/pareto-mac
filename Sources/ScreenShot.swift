// A picture of the front window, for text drawn as a picture (Figma, a photo on a page, a
// canvas). Only taken when the window's own text doesn't answer, only with the Screen
// Recording permission, and never kept: Vision reads it on this Mac and it's dropped.
// Needs macOS 14, for ScreenCaptureKit's single-picture call.

import AppKit
import ScreenCaptureKit

enum ScreenShot {
    /// macOS 14 or later: the version that can take one picture of one window.
    static var supported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// The Screen Recording permission, under Privacy & Security. macOS only reports a new
    /// permission after the app is reopened.
    static var allowed: Bool { supported && CGPreflightScreenCaptureAccess() }

    /// Shows macOS's own prompt, which adds this app to the Screen Recording list, and opens it.
    static func askForPermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `work`'s result, or nil if it takes longer than `seconds`. The work isn't stopped, only
    /// no longer waited for, since macOS's capture calls can't be cancelled.
    static func within<T>(_ seconds: Double, _ work: @escaping () async -> T?) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (finish: CheckedContinuation<T?, Never>) in
            Task {
                let value = await work()
                if once.claim() { finish.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { finish.resume(returning: nil) }
            }
        }
    }

    /// Takes a picture of `pid`'s window nearest `frame` (the front window, as Accessibility
    /// reported it), and reads its text. Line boxes come back in screen points from the
    /// top-left, like Accessibility's, so the glow can be drawn around an answer.
    static func readWindow(pid: pid_t, frame: CGRect?) async -> (blocks: [[OCRLine]], ms: Int)? {
        guard #available(macOS 14.0, *), allowed else { return nil }
        let started = Date()
        // Windows on any desktop: the front app's window may be on a desktop other than the one
        // this list thinks is current (next to a full-screen app, say).
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60
        }
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
        }
        let window = frame.flatMap { f in windows.min { distance($0.frame, f) < distance($1.frame, f) } } ?? windows.first
        guard let window else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }

        let place = window.frame
        let blocks = await Task.detached(priority: .userInitiated) { () -> [[OCRLine]] in
            let size = CGSize(width: image.width, height: image.height)
            return OCR.blocks(OCR.lines(in: image), size: size).map { lines in
                lines.map { line in
                    var line = line
                    line.box = CGRect(x: place.minX + line.box.minX * place.width, y: place.minY + line.box.minY * place.height,
                                      width: line.box.width * place.width, height: line.box.height * place.height)
                    return line
                }
            }
        }.value
        return (blocks, Int(Date().timeIntervalSince(started) * 1000))
    }
}

/// Lets only the first of two racing tasks finish a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
