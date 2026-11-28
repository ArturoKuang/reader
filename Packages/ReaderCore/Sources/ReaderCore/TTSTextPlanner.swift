import Foundation

/// A resolved "read from here" request.
public struct TTSStartMatch: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The whole quote was found.
        case exact
        /// Only the opening words of the quote were found.
        case partial
        /// Nothing matched; this is the start of the preferred page or section.
        case pageOrSection
    }
    public var target: TTSSeekTarget
    public var kind: Kind
}

public enum TTSTextPlanner {
    public static let defaultMaxUTF16Length = 360

    public struct PageSource: Equatable, Sendable {
        public var pageIndex: Int
        public var text: String

        public init(pageIndex: Int, text: String) {
            self.pageIndex = pageIndex
            self.text = text
        }
    }

    public struct OutlineBound: Equatable, Sendable {
        public var title: String
        public var startPageIndex: Int

        public init(title: String, startPageIndex: Int) {
            self.title = title
            self.startPageIndex = startPageIndex
        }
    }

    public struct WebSectionSource: Equatable, Sendable {
        public var sectionIndex: Int
        public var title: String
        public var text: String

        public init(sectionIndex: Int, title: String, text: String) {
            self.sectionIndex = sectionIndex
            self.title = title
            self.text = text
        }
    }

    public enum LineBreaks: Sendable {
        /// Every newline ends a sentence (block-structured text).
        case boundary
        /// Single newlines are layout wraps; only blank lines end a sentence (PDF).
        case soft
    }

    public typealias Segment = (range: TTSUTF16Range, text: String, words: [TTSUTF16Range])

    // MARK: - Chapter builders

    /// Chapters follow the outline; pages before the first entry form their own
    /// chapter. Without a usable outline, pages are grouped in fixed chunks.
    /// Chapters with no speakable text are omitted.
    public static func planPDF(pages: [PageSource], outline: [OutlineBound], fallbackChunkSize: Int = 10) -> [TTSChapterPlan] {
        let ordered = pages.sorted { $0.pageIndex < $1.pageIndex }
        guard let lastPage = ordered.last?.pageIndex else { return [] }

        var bounds: [OutlineBound] = []
        let sorted = outline.enumerated()
            .filter { (0...lastPage).contains($0.element.startPageIndex) }
            .sorted { ($0.element.startPageIndex, $0.offset) < ($1.element.startPageIndex, $1.offset) }
        for (_, bound) in sorted where bounds.last?.startPageIndex != bound.startPageIndex {
            bounds.append(bound)
        }

        var groups: [(title: String, pages: [PageSource])] = []
        if bounds.isEmpty {
            let size = max(fallbackChunkSize, 1)
            for start in stride(from: 0, to: ordered.count, by: size) {
                let chunk = Array(ordered[start..<min(start + size, ordered.count)])
                groups.append((pageTitle(chunk), chunk))
            }
        } else {
            let front = ordered.filter { $0.pageIndex < bounds[0].startPageIndex }
            if !front.isEmpty { groups.append((pageTitle(front), front)) }
            for (index, bound) in bounds.enumerated() {
                let end = index + 1 < bounds.count ? bounds[index + 1].startPageIndex : Int.max
                let members = ordered.filter { $0.pageIndex >= bound.startPageIndex && $0.pageIndex < end }
                groups.append((bound.title, members))
            }
        }

        return plans(groups.map { group in
            var drafts: [TTSDocumentSegment] = []
            var sentenceBase = 0
            for page in group.pages {
                let pieces = split(page.text, maxUTF16Length: defaultMaxUTF16Length, lineBreaks: .soft)
                for piece in pieces {
                    // Same UTF-16 length, so offsets into the page stay valid.
                    let spoken = String(String.UnicodeScalarView(piece.text.unicodeScalars.map {
                        CharacterSet.newlines.contains($0) ? " " : $0
                    }))
                    drafts.append(TTSDocumentSegment(
                        sentenceIndex: sentenceBase + piece.sentence,
                        text: spoken,
                        wordRanges: piece.words,
                        locator: .pdf(pageIndex: page.pageIndex, utf16Range: piece.range)
                    ))
                }
                sentenceBase += (pieces.last?.sentence).map { $0 + 1 } ?? 0
            }
            return (group.title, drafts)
        })
    }

    /// One chapter per section that has speakable text.
    public static func planWeb(sections: [WebSectionSource], lineBreaks: LineBreaks = .boundary) -> [TTSChapterPlan] {
        plans(sections.map { section in
            let drafts = split(section.text, maxUTF16Length: defaultMaxUTF16Length, lineBreaks: lineBreaks).map { piece in
                TTSDocumentSegment(
                    sentenceIndex: piece.sentence,
                    text: piece.text,
                    wordRanges: piece.words,
                    locator: .web(sectionIndex: section.sectionIndex, textOffset: piece.range.location, textLength: piece.range.length)
                )
            }
            return (section.title, drafts)
        })
    }

    /// One chapter per spine item with text; the section index is the spine
    /// index. Offsets refer to the extracted plain text, not the live DOM; use
    /// `planWeb` with DOM text when highlighting.
    public static func planEPUB(_ book: EPUBBook) -> [TTSChapterPlan] {
        let placements = SpineChapters.placements(spine: book.spine, toc: book.toc)
        return planWeb(sections: book.spine.enumerated().map { index, item in
            let title = placements[index].title
            return WebSectionSource(
                sectionIndex: index,
                title: title.isEmpty ? "Section \(index + 1)" : title,
                text: book.xhtml(for: item.href).map(epubText) ?? ""
            )
        })
    }

    /// One chapter per heading section; frontmatter is never part of a section.
    /// Offsets refer to `MarkdownSection.plainText`, not the live DOM.
    public static func planMarkdown(_ model: MarkdownDocumentModel) -> [TTSChapterPlan] {
        planWeb(sections: model.sections.map {
            WebSectionSource(sectionIndex: $0.index, title: $0.title.isEmpty ? model.title : $0.title, text: $0.plainText)
        })
    }

    private static func epubText(_ xhtml: String) -> String {
        let body = xhtml.range(of: "<body", options: .caseInsensitive).map { String(xhtml[$0.lowerBound...]) } ?? xhtml
        // Source wrapping is not a sentence break; block tags add real ones.
        return XHTMLText.plain(body.components(separatedBy: .newlines).joined(separator: " "))
    }

    private static func pageTitle(_ pages: [PageSource]) -> String {
        guard let first = pages.first?.pageIndex, let last = pages.last?.pageIndex else { return "" }
        return first == last ? "Page \(first + 1)" : "Pages \(first + 1)–\(last + 1)"
    }

    private static func plans(_ chapters: [(title: String, segments: [TTSDocumentSegment])]) -> [TTSChapterPlan] {
        let speakable = chapters.filter { !$0.segments.isEmpty }
        return speakable.enumerated().map { index, chapter in
            TTSChapterPlan(chapterIndex: index, title: chapter.title, totalChapters: speakable.count, segments: chapter.segments)
        }
    }

    // MARK: - Segmentation

    /// Sentences (and clauses of over-long sentences) as verbatim slices of
    /// `text`. Word ranges are relative to each slice.
    public static func segmentText(
        _ text: String,
        maxUTF16Length: Int = defaultMaxUTF16Length,
        lineBreaks: LineBreaks = .boundary
    ) -> [Segment] {
        split(text, maxUTF16Length: maxUTF16Length, lineBreaks: lineBreaks).map { ($0.range, $0.text, $0.words) }
    }

    public static func wordRanges(in text: String) -> [TTSUTF16Range] {
        var ranges: [TTSUTF16Range] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            ranges.append(TTSUTF16Range(NSRange(range, in: text)))
        }
        return ranges
    }

    private struct Piece {
        var range: TTSUTF16Range
        var text: String
        var words: [TTSUTF16Range]
        var sentence: Int
    }

    private static func split(_ text: String, maxUTF16Length: Int, lineBreaks: LineBreaks) -> [Piece] {
        // Working in graphemes means no cut can divide a surrogate pair or cluster.
        let characters = Array(text)
        var offsets = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters { offsets.append(offsets[offsets.count - 1] + character.utf16.count) }

        var pieces: [Piece] = []
        var sentence = 0
        for bounds in sentenceBounds(characters, lineBreaks: lineBreaks) {
            var produced = false
            for clause in clauses(characters, offsets: offsets, in: bounds, limit: max(maxUTF16Length, 1)) {
                let slice = String(characters[clause])
                guard slice.contains(where: { $0.isLetter || $0.isNumber || $0.unicodeScalars.first?.properties.isEmojiPresentation == true }) else { continue }
                let range = TTSUTF16Range(location: offsets[clause.lowerBound], length: offsets[clause.upperBound] - offsets[clause.lowerBound])
                pieces.append(Piece(range: range, text: slice, words: wordRanges(in: slice), sentence: sentence))
                produced = true
            }
            if produced { sentence += 1 }
        }
        return pieces
    }

    private static let latinTerminators: Set<Character> = [".", "!", "?", "…", "؟", "।"]
    private static let wideTerminators: Set<Character> = ["。", "！", "？", "｡"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»", "」", "』", "）"]

    private static func sentenceBounds(_ c: [Character], lineBreaks: LineBreaks) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0

        func close(_ end: Int) {
            var low = start
            var high = end
            while low < high, c[low].isWhitespace { low += 1 }
            while high > low, c[high - 1].isWhitespace { high -= 1 }
            if low < high { result.append(low..<high) }
            start = end
        }

        var index = 0
        while index < c.count {
            let character = c[index]
            if character.isNewline {
                var next = index + 1
                while next < c.count, c[next].isWhitespace, !c[next].isNewline { next += 1 }
                if lineBreaks == .boundary || (next < c.count && c[next].isNewline) { close(index) }
                index += 1
                continue
            }
            guard latinTerminators.contains(character) || wideTerminators.contains(character) else {
                index += 1
                continue
            }
            var end = index + 1
            var wide = wideTerminators.contains(character)
            while end < c.count, latinTerminators.contains(c[end]) || wideTerminators.contains(c[end]) || closers.contains(c[end]) {
                if wideTerminators.contains(c[end]) { wide = true }
                end += 1
            }
            if wide || end == c.count || (c[end].isWhitespace && endsSentence(c, terminator: index, after: end, start: start)) {
                close(end)
            }
            index = end
        }
        close(c.count)
        return result
    }

    /// Abbreviations that never end a sentence.
    private static let boundAbbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "mt", "gen", "rev", "vs", "e.g", "i.e", "cf",
        "fig", "figs", "eq", "eqs", "vol", "pp", "ch", "sec", "approx",
    ]
    /// Abbreviations that end a sentence only before a typical sentence opener.
    private static let looseAbbreviations: Set<String> = ["etc", "al", "u.s", "u.k", "e.u", "a.m", "p.m", "inc", "ltd", "co"]
    private static let sentenceOpeners: Set<String> = [
        "The", "This", "That", "These", "Those", "It", "He", "She", "They", "We", "You", "I", "In", "On", "At",
        "But", "And", "However", "There", "Then", "When", "If", "Our", "Their", "His", "Her", "Its",
    ]

    private static func endsSentence(_ c: [Character], terminator: Int, after end: Int, start: Int) -> Bool {
        var next = end
        while next < c.count, c[next].isWhitespace { next += 1 }
        guard next < c.count else { return true }
        // "approx. five", or `"Why?" she asked`.
        if c[next].isLowercase { return false }
        guard c[terminator] == ".", end == terminator + 1 || closers.contains(c[terminator + 1]) else { return true }

        var begin = terminator
        while begin > start, c[begin - 1].isLetter || c[begin - 1].isNumber || c[begin - 1] == "." { begin -= 1 }
        let token = String(c[begin..<terminator])
        let lower = token.lowercased()
        if boundAbbreviations.contains(lower) { return false }
        if lower == "no" { return !c[next].isNumber }
        if looseAbbreviations.contains(lower) {
            var wordEnd = next
            while wordEnd < c.count, c[wordEnd].isLetter { wordEnd += 1 }
            return sentenceOpeners.contains(String(c[next..<wordEnd]))
        }
        // Initials such as "J. K. Rowling".
        if token.count == 1, let only = token.first, only.isUppercase, only != "I" { return false }
        // A list number opening the sentence: "1. Introduction".
        if !token.isEmpty, token.count <= 3, token.allSatisfy(\.isNumber),
           c[start..<begin].allSatisfy(\.isWhitespace) { return false }
        return true
    }

    private static let strongClauseMarks: Set<Character> = [";", ":", "—", "；", "："]
    private static let weakClauseMarks: Set<Character> = [",", "，", "、"]

    /// Cuts a sentence longer than `limit` UTF-16 units, preferring clause marks,
    /// then spaces, then any grapheme boundary.
    private static func clauses(_ c: [Character], offsets: [Int], in sentence: Range<Int>, limit: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = sentence.lowerBound
        while offsets[sentence.upperBound] - offsets[start] > limit {
            var strong: Int?
            var weak: Int?
            var space: Int?
            var hard = start + 1
            var index = start
            while index < sentence.upperBound, offsets[index + 1] - offsets[start] <= limit {
                let character = c[index]
                let cut = index + 1
                hard = cut
                if character.isWhitespace {
                    space = cut
                } else {
                    // ASCII marks need a following space, which protects "3,000" and "10:30".
                    let separated = !character.isASCII || (cut < sentence.upperBound && c[cut].isWhitespace)
                    // Very early marks would leave a fragment.
                    if separated, offsets[cut] - offsets[start] >= limit / 4 {
                        if strongClauseMarks.contains(character) { strong = cut }
                        if weakClauseMarks.contains(character) { weak = cut }
                    }
                }
                index += 1
            }
            let cut = strong ?? weak ?? space ?? hard
            var end = cut
            while end > start, c[end - 1].isWhitespace { end -= 1 }
            if end > start { result.append(start..<end) }
            start = cut
            while start < sentence.upperBound, c[start].isWhitespace { start += 1 }
        }
        if start < sentence.upperBound { result.append(start..<sentence.upperBound) }
        return result
    }

    // MARK: - Start from selection

    /// Finds where to start reading for a selected phrase. Matching ignores case,
    /// whitespace differences and smart punctuation, and may span segments.
    /// Among repeats, the preferred page or section wins, then the occurrence
    /// whose surroundings best agree with `prefix` and `suffix`, then the first.
    public static func findStartSegment(
        matchingQuote quote: String,
        prefix: String = "",
        suffix: String = "",
        preferredPageOrSection: Int? = nil,
        in chapters: [TTSChapterPlan]
    ) -> TTSStartMatch? {
        let needle = fold(quote)
        if !needle.isEmpty {
            let stream = SearchStream(chapters: chapters)
            let before = fold(prefix)
            let after = fold(suffix)
            let words = needle.split(separator: space)
            // The full quote, then progressively shorter openings of at least three words.
            var attempts: [(needle: [UInt16], kind: TTSStartMatch.Kind)] = [(needle, .exact)]
            for count in stride(from: min(words.count - 1, 12), through: 3, by: -1) {
                attempts.append((Array(words.prefix(count).joined(separator: [space])), .partial))
            }
            for attempt in attempts {
                var best: (preferred: Bool, context: Int, target: TTSSeekTarget)?
                for found in occurrences(of: attempt.needle, in: stream.units) {
                    let origin = stream.origins[found]
                    let segment = chapters[origin.chapter].segments[origin.segment]
                    let preferred = segment.locator.pageOrSectionIndex == preferredPageOrSection
                    // A shortened needle ends inside the quote, so its suffix does not apply.
                    let end = found + attempt.needle.count
                    let context = agreement(stream.units[..<found].reversed().drop { $0 == space }, before.reversed())
                        + (attempt.kind == .exact ? agreement(stream.units[end...].drop { $0 == space }, after) : 0)
                    if let current = best, (current.preferred ? 1 : 0, current.context) >= (preferred ? 1 : 0, context) { continue }
                    // Start at the beginning of the word holding the match.
                    let word = segment.wordRanges.last { $0.location <= origin.offset }
                    let offset = word.map { origin.offset < $0.end ? $0.location : origin.offset } ?? origin.offset
                    best = (preferred, context, TTSSeekTarget(chapterIndex: origin.chapter, segmentIndex: origin.segment, charOffset: offset))
                }
                if let best { return TTSStartMatch(target: best.target, kind: attempt.kind) }
            }
        }
        guard let preferredPageOrSection else { return nil }
        for (chapter, plan) in chapters.enumerated() {
            if let segment = plan.segments.first(where: { $0.locator.pageOrSectionIndex == preferredPageOrSection }) {
                let target = TTSSeekTarget(chapterIndex: chapter, segmentIndex: segment.segmentIndex, charOffset: 0)
                return TTSStartMatch(target: target, kind: .pageOrSection)
            }
        }
        return nil
    }

    private static let space: UInt16 = 32

    /// Comparison form of one character; empty for invisible characters.
    private static func foldedUnits(_ character: Character) -> [UInt16] {
        switch character {
        case "“", "”", "„", "«", "»": return [34]
        case "‘", "’", "‚": return [39]
        case "–", "—", "‐", "‑", "−": return [45]
        case "\u{00AD}", "\u{200B}", "\u{FEFF}": return []
        default: return Array(character.lowercased().precomposedStringWithCanonicalMapping.utf16)
        }
    }

    private static func fold(_ text: String) -> [UInt16] {
        var units: [UInt16] = []
        for character in text {
            if character.isWhitespace {
                if let last = units.last, last != space { units.append(space) }
            } else {
                units += foldedUnits(character)
            }
        }
        if units.last == space { units.removeLast() }
        return units
    }

    /// Folded text of every segment, remembering where each unit came from.
    private struct SearchStream {
        var units: [UInt16] = []
        var origins: [(chapter: Int, segment: Int, offset: Int)] = []

        init(chapters: [TTSChapterPlan]) {
            for (chapter, plan) in chapters.enumerated() {
                for (segment, item) in plan.segments.enumerated() {
                    append(TTSTextPlanner.space, (chapter, segment, 0))
                    var offset = 0
                    for character in item.text {
                        if character.isWhitespace {
                            append(TTSTextPlanner.space, (chapter, segment, offset))
                        } else {
                            for unit in TTSTextPlanner.foldedUnits(character) { append(unit, (chapter, segment, offset)) }
                        }
                        offset += character.utf16.count
                    }
                }
            }
        }

        private mutating func append(_ unit: UInt16, _ origin: (Int, Int, Int)) {
            if unit == TTSTextPlanner.space, units.isEmpty || units.last == unit { return }
            units.append(unit)
            origins.append(origin)
        }
    }

    private static func occurrences(of needle: [UInt16], in haystack: [UInt16]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        return (0...(haystack.count - needle.count)).filter {
            haystack[$0] == needle[0] && haystack[$0..<($0 + needle.count)].elementsEqual(needle)
        }
    }

    /// Length of the shared run at the start of two sequences.
    private static func agreement<A: Sequence, B: Sequence>(_ left: A, _ right: B) -> Int where A.Element == UInt16, B.Element == UInt16 {
        zip(left, right).prefix { $0 == $1 }.count
    }

    // MARK: - Live reload

    /// The new position of the sentence that was playing: the identical segment
    /// nearest the old position, otherwise the segment now at that position.
    public static func reconcile(
        previousText: String,
        previousChapter: Int,
        previousSegment: Int,
        in newPlans: [TTSChapterPlan]
    ) -> (chapterIndex: Int, segmentIndex: Int)? {
        let matches = newPlans.flatMap(\.segments).filter { $0.text == previousText }
        func distance(_ segment: TTSDocumentSegment) -> (Int, Int) {
            (abs(segment.chapterIndex - previousChapter), abs(segment.segmentIndex - previousSegment))
        }
        if let match = matches.min(by: { distance($0) < distance($1) }) {
            return (match.chapterIndex, match.segmentIndex)
        }
        guard !newPlans.isEmpty else { return nil }
        let chapter = min(max(previousChapter, 0), newPlans.count - 1)
        let count = newPlans[chapter].segments.count
        guard count > 0 else { return nil }
        return (chapter, min(max(previousSegment, 0), count - 1))
    }
}
