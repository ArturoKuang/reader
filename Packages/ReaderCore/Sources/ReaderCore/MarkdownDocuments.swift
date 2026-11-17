import Foundation

enum MarkdownText {
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func splitFrontMatter(_ text: String) -> (FrontMatter?, [String], [String]) {
        let all = lines(text)
        guard all.first == "---" else {
            return (nil, all, ["Missing front matter"])
        }
        var index = 1
        var fields: [String: String] = [:]
        while index < all.count, all[index] != "---" {
            let line = all[index]
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { fields[key] = value }
            }
            index += 1
        }
        if index < all.count, all[index] == "---" { index += 1 }
        let matter = FrontMatter(
            kind: fields["reader"] ?? "",
            version: Int(fields["version"] ?? "") ?? 1,
            document: fields["document"] ?? "",
            fingerprint: fields["fingerprint"] ?? "",
            pdfID: fields["pdf-id"],
            epubID: fields["epub-id"]
        )
        return (matter, Array(all.dropFirst(index)), [])
    }

    static func renderFrontMatter(_ matter: FrontMatter) -> String {
        var lines = [
            "---",
            "reader: \(matter.kind)",
            "version: \(matter.version)",
            "document: \(matter.document)",
            "fingerprint: \(matter.fingerprint)",
        ]
        if let pdfID = matter.pdfID, !pdfID.isEmpty { lines.append("pdf-id: \(pdfID)") }
        if let epubID = matter.epubID, !epubID.isEmpty { lines.append("epub-id: \(epubID)") }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    static func blockquote(_ text: String) -> String {
        if text.isEmpty { return ">" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
    }

    static func headingLocation(page: Int?, section: String?) -> String {
        switch (page, section) {
        case let (page?, section?) where !section.isEmpty:
            return "p. \(page) · \(section)"
        case let (page?, _):
            return "p. \(page)"
        case let (_, section?) where !section.isEmpty:
            return section
        default:
            return "Untitled"
        }
    }

    static func parseHeading(_ heading: String) -> (page: Int?, section: String?) {
        var text = heading
        if text.hasPrefix("## ") { text.removeFirst(3) }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("p. ") {
            let rest = text.dropFirst(3)
            let digits = rest.prefix { $0.isNumber }
            let page = Int(digits)
            var section = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            if section.hasPrefix("·") {
                section = section.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            return (page, section.isEmpty ? nil : String(section))
        }
        return (nil, text.isEmpty ? nil : text)
    }

    static func knownKeys(_ object: [String: JSONValue], drop: Set<String>) -> [String: JSONValue] {
        object.filter { !drop.contains($0.key) }
    }
}

public struct NotesDocument: Equatable, Sendable {
    public var frontMatter: FrontMatter
    public var notes: [NoteEntry]
    public var warnings: [String]

    public init(frontMatter: FrontMatter, notes: [NoteEntry], warnings: [String] = []) {
        self.frontMatter = frontMatter
        self.notes = notes
        self.warnings = warnings
    }

    public static func parse(_ text: String) -> NotesDocument {
        let (matter, body, warnings) = MarkdownText.splitFrontMatter(text)
        var notes: [NoteEntry] = []
        var extraWarnings = warnings
        var sectionFromHeading: String?
        var pageFromHeading: Int?
        var index = 0
        while index < body.count {
            let line = body[index]
            if line.hasPrefix("## ") {
                let parsed = MarkdownText.parseHeading(line)
                pageFromHeading = parsed.page
                sectionFromHeading = parsed.section
                index += 1
                continue
            }
            if line.hasPrefix("# ") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            guard let object = ReaderComment.parse(line: line)?.object else {
                if line.contains("<!--") {
                    extraWarnings.append("Ignored a note block with no readable reader anchor.")
                }
                index += 1
                continue
            }
            index += 1
            var quoteLines: [String] = []
            while index < body.count, body[index].hasPrefix(">") {
                var quote = String(body[index].dropFirst())
                if quote.hasPrefix(" ") { quote.removeFirst() }
                quoteLines.append(quote)
                index += 1
            }
            if index < body.count, body[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            var prose: [String] = []
            while index < body.count {
                let next = body[index]
                if next.hasPrefix("## ") || next.hasPrefix("# ") || ReaderComment.parse(line: next) != nil {
                    break
                }
                prose.append(next)
                index += 1
            }
            while prose.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                prose.removeLast()
            }
            notes.append(note(from: object, quoteLines: quoteLines, body: prose.joined(separator: "\n"), headingPage: pageFromHeading, headingSection: sectionFromHeading))
        }
        let front = matter ?? FrontMatter(kind: "notes", document: "", fingerprint: "")
        return NotesDocument(frontMatter: front, notes: notes, warnings: extraWarnings)
    }

    public func render() -> String {
        var out = MarkdownText.renderFrontMatter(frontMatter.withKind("notes"))
        out += "\n\n# Notes · \(frontMatter.displayTitle)\n"
        let sorted = notes.sorted { lhs, rhs in
            let lp = lhs.page ?? Int.max
            let rp = rhs.page ?? Int.max
            if lp != rp { return lp < rp }
            return lhs.id < rhs.id
        }
        for note in sorted {
            out += "\n## \(MarkdownText.headingLocation(page: note.page, section: note.section))\n"
            out += ReaderComment.render(Self.json(note)) + "\n"
            out += MarkdownText.blockquote(note.quote) + "\n\n"
            if !note.body.isEmpty {
                out += note.body
                if !note.body.hasSuffix("\n") { out += "\n" }
            }
        }
        return out
    }

    private static let dropped: Set<String> = ["id", "page", "cfi", "quote", "prefix", "suffix", "section", "created", "updated", "ai", "provider", "scope"]

    private static func note(from object: [String: JSONValue], quoteLines: [String], body: String, headingPage: Int?, headingSection: String?) -> NoteEntry {
        let quoted = quoteLines.joined(separator: "\n")
        return NoteEntry(
            id: object["id"]?.string ?? IDs.make("n"),
            page: object["page"]?.int ?? headingPage,
            cfi: object["cfi"]?.string,
            quote: object["quote"]?.string ?? quoted,
            prefix: object["prefix"]?.string ?? "",
            suffix: object["suffix"]?.string ?? "",
            section: object["section"]?.string ?? headingSection,
            created: object["created"]?.string,
            updated: object["updated"]?.string,
            ai: object["ai"]?.bool ?? false,
            provider: object["provider"]?.string,
            scope: object["scope"]?.string ?? "passage",
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            extras: MarkdownText.knownKeys(object, drop: dropped)
        )
    }

    private static func json(_ note: NoteEntry) -> JSONValue {
        var object = note.extras
        object["id"] = .string(note.id)
        if let page = note.page { object["page"] = .number(Double(page)) }
        if let cfi = note.cfi { object["cfi"] = .string(cfi) }
        object["quote"] = .string(note.quote)
        object["prefix"] = .string(note.prefix)
        object["suffix"] = .string(note.suffix)
        if let section = note.section { object["section"] = .string(section) }
        if let created = note.created { object["created"] = .string(created) }
        if let updated = note.updated { object["updated"] = .string(updated) }
        if note.ai { object["ai"] = .bool(true) }
        if let provider = note.provider { object["provider"] = .string(provider) }
        if note.scope != "passage" { object["scope"] = .string(note.scope) }
        return .object(object)
    }
}

public struct HighlightsDocument: Equatable, Sendable {
    public var frontMatter: FrontMatter
    public var highlights: [HighlightEntry]
    public var warnings: [String]

    public init(frontMatter: FrontMatter, highlights: [HighlightEntry], warnings: [String] = []) {
        self.frontMatter = frontMatter
        self.highlights = highlights
        self.warnings = warnings
    }

    /// Same passage on the same page or CFI. A second highlight of that range is a duplicate.
    public func containsSameRange(quote: String, page: Int?, cfi: String?) -> Bool {
        highlights.contains { $0.quote == quote && $0.page == page && $0.cfi == cfi }
    }

    /// Drops one highlight. The next `render()` omits it from `highlights.md`.
    public mutating func removeHighlight(id: String) -> HighlightEntry? {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return nil }
        return highlights.remove(at: index)
    }

    public static func parse(_ text: String) -> HighlightsDocument {
        let (matter, body, warnings) = MarkdownText.splitFrontMatter(text)
        var highlights: [HighlightEntry] = []
        var extra = warnings
        var headingPage: Int?
        var headingSection: String?
        var index = 0
        while index < body.count {
            let line = body[index]
            if line.hasPrefix("## ") {
                let parsed = MarkdownText.parseHeading(line)
                headingPage = parsed.page
                headingSection = parsed.section
                index += 1
                continue
            }
            guard let object = ReaderComment.parse(line: line)?.object else {
                index += 1
                continue
            }
            index += 1
            var quoteLines: [String] = []
            while index < body.count, body[index].hasPrefix(">") {
                var quote = String(body[index].dropFirst())
                if quote.hasPrefix(" ") { quote.removeFirst() }
                quoteLines.append(quote)
                index += 1
            }
            guard let color = object["color"]?.int, HighlightPalette.isValid(color) else {
                extra.append("Ignored a highlight with a missing or invalid color.")
                continue
            }
            highlights.append(highlight(from: object, color: color, quoteLines: quoteLines, headingPage: headingPage, headingSection: headingSection))
        }
        let front = matter ?? FrontMatter(kind: "highlights", document: "", fingerprint: "")
        return HighlightsDocument(frontMatter: front, highlights: highlights, warnings: extra)
    }

    public func render() -> String {
        var out = MarkdownText.renderFrontMatter(frontMatter.withKind("highlights"))
        out += "\n\n# Highlights · \(frontMatter.displayTitle)\n"
        let sorted = highlights.sorted { lhs, rhs in
            let lp = lhs.page ?? Int.max
            let rp = rhs.page ?? Int.max
            if lp != rp { return lp < rp }
            return lhs.id < rhs.id
        }
        var lastHeading: String?
        for highlight in sorted {
            let heading = MarkdownText.headingLocation(page: highlight.page, section: highlight.section)
            if heading != lastHeading {
                out += "\n## \(heading)\n"
                lastHeading = heading
            }
            out += ReaderComment.render(Self.json(highlight)) + "\n"
            out += MarkdownText.blockquote(highlight.quote) + "\n"
        }
        return out
    }

    private static let dropped: Set<String> = ["id", "color", "page", "cfi", "quote", "prefix", "suffix", "section", "rects", "note"]

    private static func highlight(from object: [String: JSONValue], color: Int, quoteLines: [String], headingPage: Int?, headingSection: String?) -> HighlightEntry {
        var rects: [[Double]] = []
        if let rows = object["rects"]?.array {
            for row in rows {
                if let values = row.array?.compactMap(\.double) {
                    rects.append(values)
                }
            }
        }
        return HighlightEntry(
            id: object["id"]?.string ?? IDs.make("h"),
            color: color,
            page: object["page"]?.int ?? headingPage,
            cfi: object["cfi"]?.string,
            quote: object["quote"]?.string ?? quoteLines.joined(separator: "\n"),
            prefix: object["prefix"]?.string ?? "",
            suffix: object["suffix"]?.string ?? "",
            section: object["section"]?.string ?? headingSection,
            rects: rects,
            noteID: object["note"]?.string,
            extras: MarkdownText.knownKeys(object, drop: dropped)
        )
    }

    private static func json(_ highlight: HighlightEntry) -> JSONValue {
        var object = highlight.extras
        object["id"] = .string(highlight.id)
        object["color"] = .number(Double(highlight.color))
        if let page = highlight.page { object["page"] = .number(Double(page)) }
        if let cfi = highlight.cfi { object["cfi"] = .string(cfi) }
        object["quote"] = .string(highlight.quote)
        object["prefix"] = .string(highlight.prefix)
        object["suffix"] = .string(highlight.suffix)
        if let section = highlight.section { object["section"] = .string(section) }
        if !highlight.rects.isEmpty {
            object["rects"] = .array(highlight.rects.map { row in .array(row.map { .number($0) }) })
        }
        if let noteID = highlight.noteID { object["note"] = .string(noteID) }
        return .object(object)
    }
}

public struct WordsDocument: Equatable, Sendable {
    public var frontMatter: FrontMatter
    public var words: [WordEntry]
    public var warnings: [String]

    public init(frontMatter: FrontMatter, words: [WordEntry], warnings: [String] = []) {
        self.frontMatter = frontMatter
        self.words = words
        self.warnings = warnings
    }

    public static func parse(_ text: String) -> WordsDocument {
        let (matter, body, warnings) = MarkdownText.splitFrontMatter(text)
        var words: [WordEntry] = []
        var extra = warnings
        let chunks = splitSections(body)
        for chunk in chunks {
            guard chunk.heading.hasPrefix("## ") else { continue }
            let word = String(chunk.heading.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let entry = parseWord(word, lines: chunk.lines, warnings: &extra) {
                words.append(entry)
            }
        }
        let front = matter ?? FrontMatter(kind: "words", document: "", fingerprint: "")
        return WordsDocument(frontMatter: front, words: words, warnings: extra)
    }

    public func render() -> String {
        var out = MarkdownText.renderFrontMatter(frontMatter.withKind("words"))
        out += "\n\n# Words · \(frontMatter.displayTitle)\n"
        let sorted = words.sorted { lhs, rhs in
            let lp = lhs.lookups.first?.page ?? Int.max
            let rp = rhs.lookups.first?.page ?? Int.max
            if lp != rp { return lp < rp }
            return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
        }
        for word in sorted {
            out += "\n## \(word.word)\n"
            out += ReaderComment.render(Self.metaJSON(word)) + "\n"
            out += word.definition.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            if let explanation = word.explanation, !explanation.isEmpty {
                let provider = word.explanationProvider ?? "AI"
                out += "\nIn context (\(provider)): \(explanation)\n"
            }
            for lookup in word.lookups {
                out += "\n- \(Self.bullet(word: word.word, lookup: lookup))\n"
                out += "  " + ReaderComment.render(Self.lookupJSON(lookup)) + "\n"
            }
        }
        return out
    }

    private struct Section {
        var heading: String
        var lines: [String]
    }

    private static func splitSections(_ lines: [String]) -> [Section] {
        var sections: [Section] = []
        var current: Section?
        for line in lines {
            if line.hasPrefix("## ") {
                if let current { sections.append(current) }
                current = Section(heading: line, lines: [])
            } else if line.hasPrefix("# ") {
                continue
            } else {
                if current == nil { current = Section(heading: "", lines: []) }
                current?.lines.append(line)
            }
        }
        if let current { sections.append(current) }
        return sections
    }

    private static func parseWord(_ word: String, lines: [String], warnings: inout [String]) -> WordEntry? {
        var meta: [String: JSONValue]?
        var lookups: [LookupEntry] = []
        var prose: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let object = ReaderComment.parse(line: line)?.object {
                if object["lookup"] != nil || (meta != nil && object["quote"] != nil && object["id"] == nil) {
                    lookups.append(lookup(from: object, bullet: previousBullet(lines, index: index)))
                } else if meta == nil {
                    meta = object
                } else {
                    lookups.append(lookup(from: object, bullet: previousBullet(lines, index: index)))
                }
                index += 1
                continue
            }
            if trimmed.hasPrefix("- ") && !followingComment(lines, index: index) {
                warnings.append("Ignored a word sighting with no reader anchor: \(trimmed)")
                index += 1
                continue
            }
            if !trimmed.hasPrefix("- ") && !trimmed.hasPrefix("<!--") {
                prose.append(line)
            }
            index += 1
        }
        guard let meta else {
            warnings.append("Ignored \(word): the entry has no reader anchor.")
            return nil
        }
        let (definition, explanation, provider) = splitProse(prose)
        let dropped: Set<String> = ["id", "learned", "pronunciation", "partOfSpeech"]
        return WordEntry(
            id: meta["id"]?.string ?? "w_\(word)",
            word: word,
            definition: definition,
            explanation: explanation,
            explanationProvider: provider,
            pronunciation: meta["pronunciation"]?.string,
            partOfSpeech: meta["partOfSpeech"]?.string,
            learned: meta["learned"]?.bool ?? false,
            lookups: lookups,
            extras: MarkdownText.knownKeys(meta, drop: dropped)
        )
    }

    private static func followingComment(_ lines: [String], index: Int) -> Bool {
        var next = index + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            next += 1
        }
        guard next < lines.count else { return false }
        return ReaderComment.parse(line: lines[next]) != nil
    }

    private static func previousBullet(_ lines: [String], index: Int) -> String? {
        var previous = index - 1
        while previous >= 0, lines[previous].trimmingCharacters(in: .whitespaces).isEmpty {
            previous -= 1
        }
        guard previous >= 0 else { return nil }
        let line = lines[previous].trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("- ") ? line : nil
    }

    private static func splitProse(_ lines: [String]) -> (String, String?, String?) {
        var definition: [String] = []
        var explanation: String?
        var provider: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("In context ("), let close = trimmed.firstIndex(of: ")") {
                let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "In context (".count)..<close]
                provider = String(name)
                var rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":") { rest = rest.dropFirst().trimmingCharacters(in: .whitespaces) }
                explanation = String(rest)
            } else if !trimmed.isEmpty {
                definition.append(trimmed)
            }
        }
        return (definition.joined(separator: "\n"), explanation, provider)
    }

    private static func lookup(from object: [String: JSONValue], bullet: String?) -> LookupEntry {
        let parsed = bullet.flatMap(parseBullet)
        let dropped: Set<String> = ["lookup", "id", "page", "cfi", "quote", "prefix", "suffix", "section", "sentence", "date"]
        return LookupEntry(
            id: object["lookup"]?.string ?? object["id"]?.string ?? IDs.make("l"),
            page: object["page"]?.int ?? parsed?.page,
            cfi: object["cfi"]?.string,
            section: object["section"]?.string ?? parsed?.section,
            quote: object["quote"]?.string ?? "",
            prefix: object["prefix"]?.string ?? "",
            suffix: object["suffix"]?.string ?? "",
            sentence: object["sentence"]?.string ?? parsed?.sentence ?? "",
            date: object["date"]?.string ?? parsed?.date ?? "",
            extras: MarkdownText.knownKeys(object, drop: dropped)
        )
    }

    private struct Bullet {
        var page: Int?
        var section: String?
        var date: String
        var sentence: String
    }

    private static func parseBullet(_ line: String) -> Bullet? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("- ") else { return nil }
        text.removeFirst(2)
        var sentence = ""
        if let range = text.range(of: " · \"", options: .backwards) {
            sentence = String(text[range.upperBound...])
            if sentence.hasSuffix("\"") { sentence.removeLast() }
            sentence = sentence.replacingOccurrences(of: "**", with: "")
            text = String(text[..<range.lowerBound])
        }
        let parts = text.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        var page: Int?
        var section: String?
        var date = ""
        if let first = parts.first, first.hasPrefix("p. ") {
            page = Int(first.dropFirst(3).prefix { $0.isNumber })
        }
        if parts.count >= 3 {
            section = parts[1]
            date = parts[2]
        } else if parts.count == 2 {
            date = parts[1]
        }
        return Bullet(page: page, section: section, date: date, sentence: sentence)
    }

    private static func bullet(word: String, lookup: LookupEntry) -> String {
        let location: String
        if let page = lookup.page {
            location = "p. \(page)"
        } else if let cfi = lookup.cfi {
            location = cfi
        } else {
            location = "unknown"
        }
        let section = lookup.section ?? ""
        let date = displayDate(lookup.date)
        let sentence = lookup.sentence.isEmpty ? emphasized(word: word, lookup: lookup) : emphasize(word: lookup.quote.isEmpty ? word : lookup.quote, in: lookup.sentence)
        var pieces = [location]
        if !section.isEmpty { pieces.append(section) }
        if !date.isEmpty { pieces.append(date) }
        pieces.append("\"\(sentence)\"")
        return pieces.joined(separator: " · ")
    }

    private static func emphasized(word: String, lookup: LookupEntry) -> String {
        let sentence = lookup.prefix + (lookup.quote.isEmpty ? word : lookup.quote) + lookup.suffix
        return emphasize(word: lookup.quote.isEmpty ? word : lookup.quote, in: sentence)
    }

    private static func emphasize(word: String, in sentence: String) -> String {
        guard !word.isEmpty, let range = sentence.range(of: word) else { return sentence }
        return sentence.replacingCharacters(in: range, with: "**\(word)**")
    }

    static func displayDate(_ raw: String) -> String {
        if raw.count >= 16, raw.contains("T") {
            let date = raw.prefix(10)
            let time = raw.dropFirst(11).prefix(5)
            return "\(date) \(time)"
        }
        return raw
    }

    private static func metaJSON(_ word: WordEntry) -> JSONValue {
        var object = word.extras
        object["id"] = .string(word.id)
        object["learned"] = .bool(word.learned)
        if let pronunciation = word.pronunciation { object["pronunciation"] = .string(pronunciation) }
        if let part = word.partOfSpeech { object["partOfSpeech"] = .string(part) }
        return .object(object)
    }

    private static func lookupJSON(_ lookup: LookupEntry) -> JSONValue {
        var object = lookup.extras
        object["lookup"] = .string(lookup.id)
        if let page = lookup.page { object["page"] = .number(Double(page)) }
        if let cfi = lookup.cfi { object["cfi"] = .string(cfi) }
        object["quote"] = .string(lookup.quote)
        object["prefix"] = .string(lookup.prefix)
        object["suffix"] = .string(lookup.suffix)
        if let section = lookup.section { object["section"] = .string(section) }
        if !lookup.sentence.isEmpty { object["sentence"] = .string(lookup.sentence) }
        if !lookup.date.isEmpty { object["date"] = .string(lookup.date) }
        return .object(object)
    }
}

public struct MarksDocument: Equatable, Sendable {
    public var frontMatter: FrontMatter
    public var marks: [MarkEntry]
    public var warnings: [String]

    public init(frontMatter: FrontMatter, marks: [MarkEntry], warnings: [String] = []) {
        self.frontMatter = frontMatter
        self.marks = marks
        self.warnings = warnings
    }

    public static func parse(_ text: String, forcedScope: MarkScope? = nil) -> MarksDocument {
        let (matter, body, warnings) = MarkdownText.splitFrontMatter(text)
        var marks: [MarkEntry] = []
        var extra = warnings
        var index = 0
        while index < body.count {
            let line = body[index]
            guard let object = ReaderComment.parse(line: line)?.object else {
                index += 1
                continue
            }
            guard let symbol = object["symbol"]?.string, !symbol.isEmpty else {
                extra.append("Ignored a mark with no symbol.")
                index += 1
                continue
            }
            let scope = forcedScope ?? (object["scope"]?.string == "global" ? .global : MarkScope.forSymbol(symbol))
            let position = ReadingPosition(
                page: object["page"]?.int,
                scrollY: object["scrollY"]?.double,
                zoom: object["zoom"]?.double,
                pdfX: object["pdfX"]?.double,
                pdfY: object["pdfY"]?.double,
                cfi: object["cfi"]?.string,
                section: object["section"]?.string,
                quote: object["quote"]?.string,
                prefix: object["prefix"]?.string,
                suffix: object["suffix"]?.string
            )
            marks.append(MarkEntry(
                id: object["id"]?.string ?? "m_\(symbol)",
                symbol: symbol,
                scope: scope,
                position: position,
                bookFingerprint: object["bookFingerprint"]?.string,
                bookPath: object["bookPath"]?.string,
                documentTitle: object["document"]?.string,
                setAt: object["setAt"]?.string ?? ""
            ))
            index += 1
        }
        let front = matter ?? FrontMatter(kind: "marks", document: "", fingerprint: "")
        return MarksDocument(frontMatter: front, marks: marks, warnings: extra)
    }

    public func render() -> String {
        var out = MarkdownText.renderFrontMatter(frontMatter.withKind("marks"))
        let title = frontMatter.document == "global" ? "All books" : frontMatter.displayTitle
        out += "\n\n# Marks · \(title)\n"
        let sorted = marks.sorted { $0.symbol < $1.symbol }
        for mark in sorted {
            out += "\n## \(mark.symbol)\n"
            out += ReaderComment.render(Self.json(mark)) + "\n"
            if let quote = mark.position.quote, !quote.isEmpty {
                out += MarkdownText.blockquote(quote) + "\n"
            }
            out += "\n\(MarkdownText.headingLocation(page: mark.position.page, section: mark.position.section))\n"
        }
        return out
    }

    private static func json(_ mark: MarkEntry) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(mark.id),
            "symbol": .string(mark.symbol),
            "scope": .string(mark.scope.rawValue),
        ]
        let position = mark.position
        if let page = position.page { object["page"] = .number(Double(page)) }
        if let scrollY = position.scrollY { object["scrollY"] = .number(scrollY) }
        if let zoom = position.zoom { object["zoom"] = .number(zoom) }
        if let pdfX = position.pdfX { object["pdfX"] = .number(pdfX) }
        if let pdfY = position.pdfY { object["pdfY"] = .number(pdfY) }
        if let cfi = position.cfi { object["cfi"] = .string(cfi) }
        if let section = position.section { object["section"] = .string(section) }
        if let quote = position.quote { object["quote"] = .string(quote) }
        if let prefix = position.prefix { object["prefix"] = .string(prefix) }
        if let suffix = position.suffix { object["suffix"] = .string(suffix) }
        if let fingerprint = mark.bookFingerprint { object["bookFingerprint"] = .string(fingerprint) }
        if let path = mark.bookPath { object["bookPath"] = .string(path) }
        if let title = mark.documentTitle { object["document"] = .string(title) }
        if !mark.setAt.isEmpty { object["setAt"] = .string(mark.setAt) }
        return .object(object)
    }
}
