import Foundation

public struct VocabEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var word: String
    public var chapter: Int?
    public var page: Int?
    public var meaning: String
    public var bookContext: String
    public var plainLanguage: String?
    public var example: String?
    public var added: String
    public var readerOwned: Bool

    public init(id: String, word: String, chapter: Int?, page: Int? = nil, meaning: String, bookContext: String, plainLanguage: String? = nil, example: String? = nil, added: String, readerOwned: Bool) {
        self.id = id
        self.word = word
        self.chapter = chapter
        self.page = page
        self.meaning = meaning
        self.bookContext = bookContext
        self.plainLanguage = plainLanguage
        self.example = example
        self.added = added
        self.readerOwned = readerOwned
    }
}

public enum LongDate {
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    public static func format(year: Int, month: Int, day: Int) -> String {
        guard months.indices.contains(month - 1) else { return "\(year)-\(month)-\(day)" }
        return "\(months[month - 1]) \(day), \(year)"
    }
}

public enum VocabularyFile {
    public static func header(title: String) -> String {
        "# Vocabulary — \(title)"
    }

    public static func parse(_ text: String) -> [VocabEntry] {
        var entries: [VocabEntry] = []
        var chapter: Int?
        var page: Int?
        var entryPage: Int?
        var word: String?
        var fields: [String: String] = [:]
        var ownedID: String?
        func flush() {
            guard let word, !word.isEmpty else { return }
            let resolvedPage = entryPage ?? page
            let handKey = chapter.map(String.init) ?? resolvedPage.map { "p\($0)" } ?? "x"
            entries.append(VocabEntry(
                id: ownedID ?? "hand-\(handKey)-\(word.lowercased())",
                word: word,
                chapter: chapter,
                page: resolvedPage,
                meaning: fields["Meaning"] ?? "",
                bookContext: fields["Book context"] ?? "",
                plainLanguage: fields["In plain language"],
                example: fields["Example"],
                added: fields["Added"] ?? "",
                readerOwned: ownedID != nil
            ))
            selfReset()
        }
        func selfReset() {
            word = nil
            fields = [:]
            ownedID = nil
            entryPage = nil
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## Chapter ") {
                flush()
                let digits = line.dropFirst("## Chapter ".count).prefix { $0.isNumber }
                chapter = Int(digits)
                page = nil
                continue
            }
            if line.hasPrefix("## Page ") {
                flush()
                let digits = line.dropFirst("## Page ".count).prefix { $0.isNumber }
                page = Int(digits)
                chapter = nil
                continue
            }
            if line.hasPrefix("### ") {
                flush()
                word = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let comment = ReaderComment.parse(line: line)?.object, let id = comment["id"]?.string {
                ownedID = id
                if let commentPage = comment["page"]?.int {
                    entryPage = commentPage
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- **"), let close = trimmed.range(of: ":**") else { continue }
            let label = String(trimmed.dropFirst(4)[..<close.lowerBound])
            var value = trimmed[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("“") && value.hasSuffix("”")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value = String(value.dropFirst().dropLast())
            }
            fields[label] = value
        }
        flush()
        return entries
    }

    /// Appends a Reader-owned word under `## Chapter N`, creating that heading in numeric order.
    /// Existing lines are not reordered. Hand-written entries are left alone.
    public static func upsert(_ text: String, title: String, entry: VocabEntry) -> String {
        let block = render(entry)
        if let existing = parse(text).first(where: { $0.readerOwned && $0.id == entry.id }) {
            return replaceOwned(text, id: existing.id, with: block)
        }
        var source = text
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = header(title: title) + "\n"
        }
        let lines = source.components(separatedBy: "\n")
        guard let heading = sectionHeading(for: entry) else {
            return appendUngrouped(source, block: block)
        }
        if let index = lines.firstIndex(where: { $0 == heading }) {
            var insertAt = lines.count
            var cursor = index + 1
            while cursor < lines.count, !lines[cursor].hasPrefix("## ") {
                cursor += 1
            }
            insertAt = cursor
            var copy = lines
            if insertAt > 0, copy[insertAt - 1] != "" { copy.insert("", at: insertAt); insertAt += 1 }
            copy.insert(block, at: insertAt)
            return copy.joined(separator: "\n")
        }
        let insertion = insertionIndex(lines: lines, heading: heading, number: entry.chapter ?? entry.page)
        var copy = lines
        var chunk = heading + "\n\n" + block
        if insertion > 0 && insertion <= copy.count {
            if insertion == copy.count {
                if !source.hasSuffix("\n") { chunk = "\n" + chunk }
                return source + (source.hasSuffix("\n") ? "\n" : "\n") + chunk + "\n"
            }
        }
        copy.insert(chunk, at: insertion)
        return copy.joined(separator: "\n")
    }

    public static func heading(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    /// The first dictionary sense, not the whole entry.
    public static func shortMeaning(_ definition: String) -> String {
        let lines = definition.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = lines.joined(separator: " ")
        guard !text.isEmpty else { return "" }
        var sense = text
        if let numbered = text.range(of: #"\d+\s*[\.\)]\s+"#, options: .regularExpression) {
            sense = String(text[numbered.upperBound...])
        }
        sense = sense.split(separator: ";").first.map(String.init) ?? sense
        if let period = sense.firstIndex(of: "."), sense.distance(from: sense.startIndex, to: period) > 0, sense.distance(from: sense.startIndex, to: period) < 90 {
            sense = String(sense[..<period])
        }
        return sense.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func render(_ entry: VocabEntry) -> String {
        var lines = ["### \(heading(entry.word))"]
        lines.append("- **Meaning:** \(shortMeaning(entry.meaning))")
        lines.append("- **Book context:** “\(entry.bookContext)”")
        if let plain = entry.plainLanguage, !plain.isEmpty {
            lines.append("- **In plain language:** \(plain)")
        }
        if let example = entry.example, !example.isEmpty {
            lines.append("- **Example:** \(example)")
        }
        lines.append("- **Added:** \(entry.added)")
        if let page = entry.page, page > 0 {
            lines.append("<!-- reader {\"id\":\"\(entry.id)\",\"page\":\(page)} -->")
        } else {
            lines.append("<!-- reader {\"id\":\"\(entry.id)\"} -->")
        }
        return lines.joined(separator: "\n")
    }

    /// Removes a vocabulary entry matching `id` (for Reader-owned blocks) or `word` (for hand-written `### Word` sections).
    /// Drops a `## Chapter N` or `## Page N` heading if no entries remain beneath it.
    public static func remove(_ text: String, id: String, word: String? = nil) -> String {
        guard !text.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        var rangeToRemove: ClosedRange<Int>?

        if let marker = lines.firstIndex(where: { $0.contains("\"id\":\"\(id)\"") || $0.contains("\"id\": \"\(id)\"") }) {
            var start = marker
            while start > 0, !lines[start].hasPrefix("### ") { start -= 1 }
            if lines[start].hasPrefix("### ") {
                rangeToRemove = start...marker
            }
        }

        if rangeToRemove == nil, let word, !word.isEmpty {
            let needle = WordStore.normalize(word)
            for index in lines.indices where lines[index].hasPrefix("### ") {
                let headingWord = WordStore.normalize(String(lines[index].dropFirst(4)))
                if headingWord == needle {
                    var end = index
                    while end + 1 < lines.count,
                          !lines[end + 1].hasPrefix("### "),
                          !lines[end + 1].hasPrefix("## ") {
                        end += 1
                    }
                    while end > index, lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                        end -= 1
                    }
                    rangeToRemove = index...end
                    break
                }
            }
        }

        guard let range = rangeToRemove else { return text }
        var start = range.lowerBound
        var end = range.upperBound
        if end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end += 1
        } else if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            start -= 1
        }
        lines.removeSubrange(start...end)

        // Remove an empty ## Chapter / ## Page section if removing this entry left it empty.
        var scan = min(start, lines.count) - 1
        while scan >= 0, lines[scan].trimmingCharacters(in: .whitespaces).isEmpty {
            scan -= 1
        }
        if scan >= 0, (lines[scan].hasPrefix("## Chapter ") || lines[scan].hasPrefix("## Page ")) {
            var next = scan + 1
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                next += 1
            }
            if next == lines.count || lines[next].hasPrefix("## ") {
                var sectionStart = scan
                if sectionStart > 0, lines[sectionStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    sectionStart -= 1
                }
                lines.removeSubrange(sectionStart..<next)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func replaceOwned(_ text: String, id: String, with block: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let marker = lines.firstIndex(where: { $0.contains("\"id\":\"\(id)\"") || $0.contains("\"id\": \"\(id)\"") }) else {
            return text
        }
        var start = marker
        while start > 0, !lines[start].hasPrefix("### ") { start -= 1 }
        var copy = lines
        copy.replaceSubrange(start...marker, with: block.components(separatedBy: "\n"))
        return copy.joined(separator: "\n")
    }

    /// A chapter heading when the book has one. A PDF page when it does not. Never `Chapter ?`.
    public static func sectionHeading(for entry: VocabEntry) -> String? {
        if let chapter = entry.chapter { return "## Chapter \(chapter)" }
        if let page = entry.page { return "## Page \(page)" }
        return nil
    }

    private static func appendUngrouped(_ source: String, block: String) -> String {
        var text = source
        if !text.hasSuffix("\n") { text += "\n" }
        if !text.hasSuffix("\n\n") { text += "\n" }
        return text + block + "\n"
    }

    private static func insertionIndex(lines: [String], heading: String, number: Int?) -> Int {
        guard let number else { return lines.count }
        let prefix = heading.hasPrefix("## Page ") ? "## Page " : "## Chapter "
        for (index, line) in lines.enumerated() where line.hasPrefix(prefix) {
            let digits = line.dropFirst(prefix.count).prefix { $0.isNumber }
            if let existing = Int(digits), existing > number { return index }
        }
        return lines.count
    }
}
