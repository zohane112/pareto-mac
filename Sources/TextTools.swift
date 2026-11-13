// Text tools shared by window and PDF search: counting words, splitting sentences, and
// turning blocks of text into the passages Jev chooses between. Same rules as the Chrome
// extension's chunker: short bits get merged, very long blocks get split at sentence ends.

import Foundation
import NaturalLanguage

enum TextTools {
    static let tiny = 8          // blocks shorter than this many words get merged with neighbours
    static let mergeUpTo = 40    // stop adding to a merged passage at this many words
    static let splitOver = 400   // blocks longer than this get split at sentence ends
    static let splitInto = 250   // about how many words each split piece gets

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into sentences, then glues back pieces that start in lower case or are
    /// under 3 words (a split after an abbreviation like "Dr.").
    static func sentences(_ text: String) -> [String] {
        let spaced = text.replacingOccurrences(of: "(?<=[a-z]{2}|[0-9%)])([.!?][\"”’')\\]]?)(?=[A-Z“\"‘])",
                                               with: "$1 ", options: .regularExpression)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = spaced
        var raw: [String] = []
        tokenizer.enumerateTokens(in: spaced.startIndex..<spaced.endIndex) { range, _ in
            let s = spaced[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { raw.append(s) }
            return true
        }
        var out: [String] = []
        for s in raw {
            let startsLower = s.first.map { $0.isLowercase } ?? false
            if let last = out.last, startsLower || words(s) < 3 || words(last) < 3 {
                out[out.count - 1] = last + " " + s
            } else {
                out.append(s)
            }
        }
        return out.isEmpty ? [text] : out
    }

    /// A passage Jev can pick: its text, plus which source blocks it came from.
    struct Passage {
        var text: String
        var blocks: [Int]
        var page: Int? = nil
        var path: [String] = []
    }

    /// Blocks in reading order → passages. `group` says which blocks may be merged together
    /// (the same PDF page, or the same part of a window).
    static func passages(_ blocks: [(text: String, group: Int, page: Int?)]) -> [Passage] {
        var merged: [Passage] = []
        var run: Passage?
        var runGroup = -1
        var runWords = 0
        func flush() {
            if let r = run { merged.append(r) }
            run = nil
            runWords = 0
        }
        for (i, block) in blocks.enumerated() {
            let text = clean(block.text)
            guard !text.isEmpty else { continue }
            let n = words(text)
            if n >= tiny {
                flush()
                merged.append(Passage(text: text, blocks: [i], page: block.page))
                continue
            }
            if run == nil || runGroup != block.group || runWords >= mergeUpTo {
                flush()
                run = Passage(text: text, blocks: [i], page: block.page)
                runGroup = block.group
            } else {
                run!.text += (run!.text.hasSuffix(":") ? " " : "; ") + text
                run!.blocks.append(i)
            }
            runWords += n
        }
        flush()

        // Very long blocks are split, so a match lands near the answer.
        var out: [Passage] = []
        for p in merged {
            guard words(p.text) > splitOver else {
                if words(p.text) >= 3 { out.append(p) }
                continue
            }
            var current: [String] = []
            var count = 0
            for s in sentences(p.text) {
                let n = words(s)
                if count > 0 && count + n > splitInto {
                    out.append(Passage(text: current.joined(separator: " "), blocks: p.blocks, page: p.page))
                    current = []
                    count = 0
                }
                current.append(s)
                count += n
            }
            if !current.isEmpty { out.append(Passage(text: current.joined(separator: " "), blocks: p.blocks, page: p.page)) }
        }
        return out
    }

    /// Words worth searching for in a request, without the filler ("open the file called...").
    static func keywords(_ query: String) -> [String] {
        let stop: Set<String> = [
            "a", "an", "the", "my", "me", "i", "to", "of", "for", "in", "on", "at", "from", "with", "about", "and", "or",
            "open", "launch", "start", "run", "find", "search", "show", "get", "look", "where", "is", "was", "are",
            "which", "that", "this", "it", "please", "can", "you", "could", "would", "file", "files", "called", "named",
            "app", "application", "up", "go", "switch", "bring", "let", "see", "some", "any", "all", "do", "did",
            "what", "whats", "what's", "there", "had", "have", "has", "be", "were", "last", "latest", "recent", "new",
            "took", "take", "made", "make", "wrote", "write", "sent", "send", "saved", "save", "downloaded", "got",
            "created", "edited", "worked", "working", "i've", "ive", "im", "i'm", "one", "thing", "stuff",
        ]
        return query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_")))
            // Short numbers ("12", "80") match too many files; years and longer numbers are kept.
            .filter { $0.count >= 2 && !stop.contains($0) && !($0.allSatisfy(\.isNumber) && $0.count < 4) }
    }
}
