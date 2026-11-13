// Finding apps and files on this Mac. Apps come from the Applications folders, files from
// Spotlight's index (the same one Spotlight uses). Nothing leaves the computer here.

import AppKit
import UniformTypeIdentifiers

struct AppEntry: Hashable {
    let name: String
    let url: URL
}

enum AppIndex {
    private static var cached: [AppEntry] = []
    private static var cachedAt = Date.distantPast
    private static let lock = NSLock()

    /// Every app in the usual places, by name. Rescanned at most once a minute.
    static func all() -> [AppEntry] {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(cachedAt) < 60, !cached.isEmpty { return cached }
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
        var byName: [String: AppEntry] = [:]
        func add(_ url: URL) {
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            if byName[name.lowercased()] == nil { byName[name.lowercased()] = AppEntry(name: name, url: url) }
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" { add(item); continue }
                // One level down, for apps kept in their own folder ("Adobe Photoshop/Photoshop.app").
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
                   let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        cached = byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedAt = Date()
        return cached
    }

    /// How well a name matches what was typed, 0 to 100. Prefix beats word start beats
    /// contained beats initials ("vsc" for Visual Studio Code) beats letters in order.
    static func match(_ name: String, _ typed: String) -> Int {
        let n = name.lowercased()
        let q = typed.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if n == q { return 100 }
        if n.hasPrefix(q) { return 90 }
        let parts = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if parts.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if n.contains(q) { return 65 }
        let initials = String(parts.compactMap(\.first))
        if q.count >= 2, initials.hasPrefix(q) { return 60 }
        if q.count >= 3 {
            var it = n.makeIterator()
            var ok = true
            for c in q where c != " " {
                var found = false
                while let x = it.next() { if x == c { found = true; break } }
                if !found { ok = false; break }
            }
            if ok { return 30 }
        }
        return 0
    }

    /// Apps whose names match the request, best first. "open slack" matches Slack.
    static func search(_ query: String, limit: Int = 5) -> [AppEntry] {
        let typed = stripCommand(query)
        guard !typed.isEmpty else { return [] }
        let usage = UsageLog.counts()
        return all()
            .map { ($0, match($0.name, typed)) }
            .filter { $0.1 > 0 }
            .sorted { a, b in
                let sa = a.1 + min(usage[a.0.url.path, default: 0], 10)
                let sb = b.1 + min(usage[b.0.url.path, default: 0], 10)
                return sa != sb ? sa > sb : a.0.name.count < b.0.name.count
            }
            .prefix(limit).map(\.0)
    }

    /// "open slack" → "slack", "launch the calculator app" → "calculator".
    static func stripCommand(_ query: String) -> String {
        var q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for verb in ["open up ", "open the ", "open ", "launch the ", "launch ", "start the ", "start ", "run ",
                     "switch to ", "go to ", "bring up ", "show me ", "show "] where q.hasPrefix(verb) {
            q = String(q.dropFirst(verb.count))
            break
        }
        for tail in [" app", " application", " please"] where q.hasSuffix(tail) {
            q = String(q.dropLast(tail.count))
        }
        return q.trimmingCharacters(in: .whitespaces)
    }
}

/// Which apps and files were opened through the bar, so they rank a little higher next time,
/// and show in the empty bar as recents.
enum UsageLog {
    static func recent() -> [String] {
        UserDefaults.standard.stringArray(forKey: "recent") ?? []
    }
    static func counts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: "usage") as? [String: Int] ?? [:]
    }
    static func record(_ path: String) {
        var c = counts()
        c[path, default: 0] += 1
        if c.count > 300 { c = Dictionary(uniqueKeysWithValues: c.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(c, forKey: "usage")
        var r = recent().filter { $0 != path }
        r.insert(path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(6)), forKey: "recent")
    }
}

struct FileHit: Hashable {
    let url: URL
    let name: String
    let kind: String
    let modified: Date?
    /// How many of the searched words are in the file's name (the rest were in its text).
    var nameMatches = 0

    var folder: String {
        let dir = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }

    /// How the file is described to Jev: name, kind, folder and when it changed.
    var described: String {
        var parts = [name, kind, "in \(folder)"]
        if let modified {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy"
            parts.append("changed \(f.string(from: modified))")
        }
        return parts.joined(separator: " · ")
    }
}

/// A Spotlight search for files, by name and by what they contain.
final class FileSearch: NSObject {
    private var query: NSMetadataQuery?
    private var done: (([FileHit]) -> Void)?
    private var timer: Timer?
    private var limit = 40
    private var terms: [String] = []

    /// Kinds of file that people name in requests, mapped to what Spotlight calls them.
    static let kindWords: [String: String] = [
        "pdf": "com.adobe.pdf", "pdfs": "com.adobe.pdf",
        "image": "public.image", "images": "public.image", "photo": "public.image", "photos": "public.image",
        "picture": "public.image", "pictures": "public.image", "screenshot": "screenshot", "screenshots": "screenshot",
        "video": "public.movie", "videos": "public.movie", "movie": "public.movie", "recording": "public.movie",
        "spreadsheet": "public.spreadsheet", "sheet": "public.spreadsheet", "excel": "public.spreadsheet",
        "presentation": "public.presentation", "slides": "public.presentation", "deck": "public.presentation", "keynote": "public.presentation",
        "doc": "public.content", "document": "public.content", "word": "public.content", "essay": "public.content",
        "song": "public.audio", "audio": "public.audio", "music": "public.audio", "voice": "public.audio",
        "folder": "public.folder", "folders": "public.folder",
    ]

    /// When only a few files match every word, the search widens to files matching any of
    /// them, so Jev still has candidates for a loosely worded request.
    private var widenTo: String?
    private var strictHits: [FileHit] = []

    /// Finds up to `limit` files for the request: files matching every word first, then (if
    /// there are few) files matching any word; within each, files named after the words come
    /// first, then the newest. Calls back on the main thread within about two seconds.
    func run(_ request: String, limit: Int = 40, done: @escaping ([FileHit]) -> Void) {
        cancel()
        let words = TextTools.keywords(request).filter { !FileSearch.timeWords.contains($0) }
        let kinds = Set(words.compactMap { FileSearch.kindWords[$0] })
        let terms = Array(words.filter { FileSearch.kindWords[$0] == nil }.prefix(4))
        guard !terms.isEmpty || !kinds.isEmpty else { done([]); return }

        func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "") }
        let termClauses = terms.map { t in
            "(kMDItemDisplayName == \"*\(escape(t))*\"cd || kMDItemTextContent == \"\(escape(t))*\"cdw)"
        }
        // Screenshots are marked by macOS itself; other kinds go by file type.
        let kindClause = kinds.isEmpty ? nil : "(" + kinds.map {
            $0 == "screenshot" ? "kMDItemIsScreenCapture == 1" : "kMDItemContentTypeTree == \"\($0)\""
        }.joined(separator: " || ") + ")"

        let strict = (termClauses + [kindClause].compactMap { $0 }).joined(separator: " && ")
        // Widening: any of the words, or (for "the screenshot about the thing") just the kind.
        if terms.count > 1 {
            widenTo = (["(" + termClauses.joined(separator: " || ") + ")"] + [kindClause].compactMap { $0 }).joined(separator: " && ")
        } else if !terms.isEmpty, let kindClause {
            widenTo = kindClause
        } else {
            widenTo = nil
        }
        strictHits = []
        self.limit = limit
        self.terms = terms
        self.done = done
        start(strict, timeout: 1.2)
    }

    /// Months and times: Jev reads them against each file's date, so Spotlight doesn't need
    /// them in the file.
    static let timeWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "sept", "october",
        "november", "december", "today", "yesterday", "tonight", "morning", "week", "weeks", "month", "months",
        "year", "years", "ago", "day", "days", "earlier", "recently", "ago", "this", "past",
    ]

    private func start(_ queryString: String, timeout: TimeInterval) {
        guard let predicate = NSPredicate(fromMetadataQueryString: queryString) else { finish(); return }
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query = q
        NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: q)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in self?.finish() }
        q.start()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        stopQuery()
        done = nil
        widenTo = nil
        strictHits = []
    }

    private func stopQuery() {
        if let q = query {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        }
        query = nil
    }

    @objc private func gathered() { finish() }

    private func finish() {
        guard done != nil else { return }
        var hits: [FileHit] = []
        if let q = query {
            q.disableUpdates()
            let home = NSHomeDirectory()
            for i in 0..<min(q.resultCount, 400) {
                guard let item = q.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                // Skip app internals, caches and hidden folders: nobody means those.
                let rel = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
                if rel.hasPrefix("/Library/") || rel.contains("/.") || rel.contains(".app/") || rel.contains("/node_modules/") { continue }
                let url = URL(fileURLWithPath: path)
                let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? url.lastPathComponent
                let lower = name.lowercased()
                hits.append(FileHit(
                    url: url,
                    name: name,
                    kind: item.value(forAttribute: "kMDItemKind") as? String ?? "file",
                    modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                    nameMatches: terms.filter { lower.contains($0) }.count))
            }
        }
        stopQuery()
        // Files named after what was typed come first; then the most recently changed.
        hits.sort { a, b in
            a.nameMatches != b.nameMatches ? a.nameMatches > b.nameMatches
                : (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
        }
        if let widen = widenTo, hits.count < 8 {
            widenTo = nil
            strictHits = hits
            start(widen, timeout: 1.0)
            return
        }
        let seen = Set(strictHits.map(\.url))
        let all = strictHits + hits.filter { !seen.contains($0.url) }
        let callback = done
        cancel()
        callback?(Array(all.prefix(limit)))
    }
}
