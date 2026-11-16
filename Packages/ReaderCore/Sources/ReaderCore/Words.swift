import Foundation

public struct WordUndo: Equatable, Sendable {
    public var word: String
    /// Nil when the word was created by the lookup that this undo removes.
    public var previous: WordEntry?

    public init(word: String, previous: WordEntry?) {
        self.word = word
        self.previous = previous
    }
}

public enum WordStore {
    public static func record(
        words: inout [WordEntry],
        word rawWord: String,
        definition: String,
        explanation: String?,
        explanationProvider: String?,
        occurrence: LookupEntry,
        id: String
    ) -> WordUndo {
        let key = normalize(rawWord)
        let previous = words.first { normalize($0.word) == key }
        let undo = WordUndo(word: key, previous: previous)
        if var existing = previous {
            if existing.definition.isEmpty, !definition.isEmpty {
                existing.definition = definition
            }
            if let explanation, !explanation.isEmpty {
                existing.explanation = explanation
                existing.explanationProvider = explanationProvider
            }
            existing.lookups.append(occurrence)
            replace(&words, existing)
        } else {
            words.append(WordEntry(
                id: id,
                word: key,
                definition: definition,
                explanation: explanation,
                explanationProvider: explanationProvider,
                lookups: [occurrence]
            ))
        }
        return undo
    }

    public static func undo(words: inout [WordEntry], _ undo: WordUndo) {
        let key = normalize(undo.word)
        if let previous = undo.previous {
            replace(&words, previous)
        } else {
            words.removeAll { normalize($0.word) == key }
        }
    }

    public static func setLearned(words: inout [WordEntry], id: String, learned: Bool) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        words[index].learned = learned
    }

    public static func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func replace(_ words: inout [WordEntry], _ entry: WordEntry) {
        if let index = words.firstIndex(where: { normalize($0.word) == normalize(entry.word) }) {
            words[index] = entry
        } else {
            words.append(entry)
        }
    }
}

public struct ExportBook: Equatable, Sendable {
    public var title: String
    public var words: [WordEntry]

    public init(title: String, words: [WordEntry]) {
        self.title = title
        self.words = words
    }
}

public enum WordExport {
    public static func markdown(books: [ExportBook], date: String) -> String {
        let merged = merge(books)
        let bookCount = books.count
        let noun = bookCount == 1 ? "book" : "books"
        var out = "# All words · exported \(date) from \(bookCount) \(noun)\n"
        for item in merged {
            out += "\n## \(item.word)\n"
            if !item.definition.isEmpty {
                out += item.definition + "\n"
            }
            for sighting in item.sightings {
                out += "- \(sighting.book) · \(sighting.location) · \"\(sighting.sentence)\"\n"
            }
        }
        return out
    }

    public static func csv(books: [ExportBook]) -> String {
        var rows = ["word,definition,learned,book,location,section,sentence,date"]
        for item in merge(books) {
            for sighting in item.sightings {
                let fields = [
                    item.word,
                    item.definition,
                    item.learned ? "true" : "false",
                    sighting.book,
                    sighting.location,
                    sighting.section,
                    sighting.sentence,
                    sighting.date,
                ].map(csvEscape)
                rows.append(fields.joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private struct Sighting {
        var book: String
        var location: String
        var section: String
        var sentence: String
        var date: String
        var page: Int
    }

    private struct Merged {
        var word: String
        var definition: String
        var learned: Bool
        var sightings: [Sighting]
    }

    private static func merge(_ books: [ExportBook]) -> [Merged] {
        var order: [String] = []
        var byWord: [String: Merged] = [:]
        for book in books {
            for entry in book.words {
                let key = WordStore.normalize(entry.word)
                if byWord[key] == nil {
                    order.append(key)
                    byWord[key] = Merged(word: key, definition: "", learned: false, sightings: [])
                }
                if byWord[key]?.definition.isEmpty == true, !entry.definition.isEmpty {
                    byWord[key]?.definition = entry.definition
                }
                if entry.learned { byWord[key]?.learned = true }
                let sightings = entry.lookups.isEmpty
                    ? [Sighting(book: book.title, location: "—", section: "", sentence: "", date: "", page: Int.max)]
                    : entry.lookups.map { lookup in
                        Sighting(
                            book: book.title,
                            location: lookup.page.map { "p. \($0)" } ?? (lookup.cfi ?? "—"),
                            section: lookup.section ?? "",
                            sentence: emphasize(lookup),
                            date: lookup.date,
                            page: lookup.page ?? Int.max
                        )
                    }
                byWord[key]?.sightings.append(contentsOf: sightings)
            }
        }
        return order.sorted().compactMap { key in
            guard var item = byWord[key] else { return nil }
            item.sightings.sort { lhs, rhs in
                if lhs.book != rhs.book { return lhs.book < rhs.book }
                return lhs.page < rhs.page
            }
            return item
        }
    }

    private static func emphasize(_ lookup: LookupEntry) -> String {
        let sentence = lookup.sentence.isEmpty
            ? lookup.prefix + lookup.quote + lookup.suffix
            : lookup.sentence
        guard !lookup.quote.isEmpty, let range = sentence.range(of: lookup.quote) else { return sentence }
        if sentence.contains("**\(lookup.quote)**") { return sentence }
        return sentence.replacingCharacters(in: range, with: "**\(lookup.quote)**")
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

public enum SentenceSpan {
    public static func sentence(containing quote: String, in text: String) -> (sentence: String, prefix: String, suffix: String)? {
        guard !quote.isEmpty, let range = text.range(of: quote) else { return nil }
        let start = boundaryStart(text, before: range.lowerBound)
        let end = boundaryEnd(text, after: range.upperBound)
        let sentence = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(text[start..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(text[range.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrefix = prefix.count > 80 ? String(prefix.suffix(80)) : prefix
        let trimmedSuffix = suffix.count > 80 ? String(suffix.prefix(80)) : suffix
        return (sentence, trimmedPrefix, trimmedSuffix)
    }

    private static func boundaryStart(_ text: String, before index: String.Index) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            if character == "\n" || character == "." || character == "?" || character == "!" {
                return cursor
            }
            cursor = previous
        }
        return text.startIndex
    }

    private static func boundaryEnd(_ text: String, after index: String.Index) -> String.Index {
        var cursor = index
        while cursor < text.endIndex {
            let character = text[cursor]
            cursor = text.index(after: cursor)
            if character == "\n" || character == "." || character == "?" || character == "!" {
                return cursor
            }
        }
        return text.endIndex
    }
}
