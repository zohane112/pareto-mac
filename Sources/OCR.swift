// Reading text in pictures with Apple's Vision, on this Mac: scanned PDF pages, image files,
// and a picture of the front window when its text is drawn as a picture (Figma, a photo of a
// page). Nothing leaves the Mac, and no picture is kept.

import AppKit
import PDFKit
import Vision

/// A line of text found in a picture, and where it is. Straight out of Vision the box is in
/// fractions of the picture (0…1, from the top-left); callers move it to page or screen points.
struct OCRLine {
    let text: String
    var box: CGRect
}

enum OCR {
    /// Every line of text Vision can read in `image`, most confident reading only.
    static func lines(in image: CGImage) -> [OCRLine] {
        // The accurate reader, or the fast one where it fails (it does under Rosetta).
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let found = lines(in: image, level: level)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func lines(in image: CGImage, level: VNRequestTextRecognitionLevel) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let b = observation.boundingBox // from the bottom-left
            return OCRLine(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
    }

    /// Lines → blocks that read as one piece, like a paragraph or a table cell. A line joins the
    /// block above it when it starts just below that block's last line and lines up with it.
    /// Blocks come back in reading order: top to bottom, and left to right within a row.
    /// `size` is the picture's size, so gaps down and across compare fairly.
    static func blocks(_ lines: [OCRLine], size: CGSize) -> [[OCRLine]] {
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        /// Could `below` continue the text of `above`: about the same size, and lined up.
        func linesUp(_ above: CGRect, _ below: CGRect) -> Bool {
            let h = max(above.height, below.height)
            let overlap = min(below.maxX, above.maxX) - max(below.minX, above.minX)
            return (abs(below.minX - above.minX) < h * 1.5 || overlap > min(below.width, above.width) * 0.6)
                && abs(below.height - above.height) < h * 0.45
        }
        let sorted = lines.sorted { $0.box.minY < $1.box.minY }
        let rects = sorted.map { px($0.box) }

        // The usual gap between a line and the one above it, in line heights. Paragraphs are
        // split where the gap is clearly bigger, so single- and double-spaced text both work.
        var gaps: [CGFloat] = []
        for k in rects.indices {
            let r = rects[k]
            let h = r.height
            if let above = rects[max(0, k - 30)..<k].last(where: { $0.maxY <= r.minY + h * 0.3 && linesUp($0, r) }) {
                let gap = (r.minY - above.maxY) / max(h, above.height)
                if gap > -0.3, gap < 3 { gaps.append(gap) }
            }
        }
        let usual = gaps.isEmpty ? 0.3 : gaps.sorted()[gaps.count / 2]
        let limit = min(1.4, max(0.45, usual * 1.4 + 0.1))

        var groups: [[OCRLine]] = []
        var groupRects: [CGRect] = [] // each group's last line, in pixels
        for (line, r) in zip(sorted, rects) {
            let target = groupRects.indices.last { i in
                let last = groupRects[i]
                let h = max(last.height, r.height)
                let gap = r.minY - last.maxY
                return gap > -h * 0.3 && gap < h * limit && linesUp(last, r)
            }
            if let t = target {
                groups[t].append(line)
                groupRects[t] = r
            } else {
                groups.append([line])
                groupRects.append(r)
            }
        }
        // Reading order: rows about one line high, then left to right.
        let heights = lines.map { px($0.box).height }.sorted()
        let band = max(heights.isEmpty ? 1 : heights[heights.count / 2], 1)
        return groups.sorted { a, b in
            let ra = px(a[0].box), rb = px(b[0].box)
            let rowA = Int(ra.minY / band), rowB = Int(rb.minY / band)
            return rowA != rowB ? rowA < rowB : ra.minX < rb.minX
        }
    }

    /// The lines of a block as one piece of text. A word broken with a hyphen at a line's end
    /// is joined back.
    static func join(_ lines: [OCRLine]) -> String {
        joined(lines).text
    }

    /// `join`'s text, plus where each line starts and ends in it (UTF-16 offsets).
    private static func joined(_ lines: [OCRLine]) -> (text: String, spans: [(start: Int, end: Int, box: CGRect)]) {
        var text = ""
        var spans: [(start: Int, end: Int, box: CGRect)] = []
        for line in lines {
            if text.hasSuffix("-"), line.text.first?.isLowercase == true {
                text.removeLast()
            } else if !text.isEmpty {
                text += " "
            }
            let start = text.utf16.count
            text += line.text
            spans.append((start, text.utf16.count, line.box))
        }
        return (text, spans)
    }

    /// Where `sentence` sits among `lines`: the box around the lines it spans. When the
    /// sentence can't be found, the box around all of them.
    static func box(of sentence: String?, in lines: [OCRLine]) -> CGRect? {
        guard let first = lines.first else { return nil }
        let all = lines.dropFirst().reduce(first.box) { $0.union($1.box) }
        guard let sentence, !sentence.isEmpty else { return all }
        let (text, spans) = joined(lines)
        let flat = TextTools.clean(sentence)
        for probe in [flat, String(flat.prefix(60)), String(flat.prefix(30))] where probe.count >= 8 {
            let found = (text as NSString).range(of: probe, options: [.caseInsensitive, .diacriticInsensitive])
            guard found.location != NSNotFound else { continue }
            let end = found.location + max(found.length, flat.utf16.count)
            let hit = spans.filter { $0.end > found.location && $0.start < end }
            if let firstHit = hit.first {
                return hit.dropFirst().reduce(firstHit.box) { $0.union($1.box) }
            }
        }
        return all
    }

    /// A PDF page as a picture big enough to read: about twice its size, at most 2,600 px long.
    static func image(of page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(2.0, 2600 / max(bounds.width, bounds.height))
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
