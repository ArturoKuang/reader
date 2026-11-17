import Foundation

public enum ConceptMatching {
    /// A find-term matches only as a whole token. Digits inside a longer number do not count.
    public static func contains(term: String, in text: String) -> Bool {
        range(of: term, in: text) != nil
    }

    public static func range(of term: String, in text: String) -> Range<String.Index>? {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let haystack = text.lowercased()
        let query = needle.lowercased()
        var cursor = haystack.startIndex
        while let found = haystack.range(of: query, range: cursor..<haystack.endIndex) {
            if isWholeToken(found, in: haystack) { return found }
            cursor = found.upperBound
        }
        return nil
    }

    private static func isWholeToken(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isTokenCharacter(before) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if isTokenCharacter(after) { return false }
        }
        return true
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }
}

public struct Concept: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var chapter: Int?
    public var prerequisites: [String]
    public var findTerms: [String]
    public var claim: String?
    public var trap: String?

    public init(id: String, title: String, chapter: Int? = nil, prerequisites: [String] = [], findTerms: [String] = [], claim: String? = nil, trap: String? = nil) {
        self.id = id
        self.title = title
        self.chapter = chapter
        self.prerequisites = prerequisites
        self.findTerms = findTerms
        self.claim = claim
        self.trap = trap
    }

    public var wiki: String { "[[\(id) \(title)]]" }
    public var stubFileName: String { "\(id) \(title).md" }
}

public enum ConceptsFile {
    public static func parse(_ text: String) -> [Concept] {
        var concepts: [Concept] = []
        var chapter: Int?
        for raw in text.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("## ") {
                chapter = chapterNumber(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- **Claim:**") || trimmed.hasPrefix("- **Trap:**"), !concepts.isEmpty {
                let value = trimmed.replacingOccurrences(of: "- **Claim:**", with: "").replacingOccurrences(of: "- **Trap:**", with: "").trimmingCharacters(in: .whitespaces)
                if trimmed.contains("Claim") {
                    concepts[concepts.count - 1].claim = value
                } else {
                    concepts[concepts.count - 1].trap = value
                }
                continue
            }
            guard trimmed.hasPrefix("- "), let parsed = parseConceptLine(trimmed) else { continue }
            var concept = parsed
            concept.chapter = chapter
            concepts.append(concept)
        }
        return concepts
    }

    public static func autocomplete(prefix: String, concepts: [Concept]) -> [Concept] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty { return concepts }
        return concepts.filter {
            $0.id.lowercased().hasPrefix(needle) || $0.title.lowercased().contains(needle) || "\($0.id) \($0.title)".lowercased().hasPrefix(needle)
        }
    }

    public static func suggested(passage: String, concepts: [Concept], chapter: Int?) -> [Concept] {
        concepts.filter { concept in
            if let own = concept.chapter {
                guard let chapter, own == chapter else { return false }
            }
            return concept.findTerms.contains { ConceptMatching.contains(term: $0, in: passage) }
        }
    }

    public static func stub(for concept: Concept) -> String {
        var lines = ["# \(concept.id) · \(concept.title)", ""]
        if let claim = concept.claim, !claim.isEmpty { lines.append("**Claim:** \(claim)") ; lines.append("") }
        if let trap = concept.trap, !trap.isEmpty { lines.append("**Trap:** \(trap)") ; lines.append("") }
        return lines.joined(separator: "\n")
    }

    private static func chapterNumber(_ heading: String) -> Int? {
        let lowered = heading.lowercased()
        guard let range = lowered.range(of: "ch ") ?? lowered.range(of: "ch. ") ?? lowered.range(of: "chapter ") else {
            return ChapterFiles.number(in: heading)
        }
        let digits = lowered[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func parseConceptLine(_ line: String) -> Concept? {
        guard let open = line.range(of: "**"), let close = line.range(of: "**", range: open.upperBound..<line.endIndex) else { return nil }
        let inner = String(line[open.upperBound..<close.lowerBound])
        let pieces = inner.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let id = pieces.first, isConceptID(id) else { return nil }
        let title = pieces.dropFirst().joined(separator: " · ")
        let rest = String(line[close.upperBound...])
        return Concept(id: id, title: title, prerequisites: list(after: "pre:", in: rest), findTerms: backticks(in: rest))
    }

    private static func isConceptID(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter, first.isUppercase else { return false }
        return text.contains(where: \.isNumber)
    }

    private static func list(after label: String, in text: String) -> [String] {
        guard let range = text.range(of: label) else { return [] }
        var rest = text[range.upperBound...]
        if let find = rest.range(of: "find:") { rest = rest[..<find.lowerBound] }
        return rest.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "· "))
        }.filter { !$0.isEmpty }
    }

    private static func backticks(in text: String) -> [String] {
        var terms: [String] = []
        var cursor = text.startIndex
        while let open = text.range(of: "`", range: cursor..<text.endIndex) {
            guard let close = text.range(of: "`", range: open.upperBound..<text.endIndex) else { break }
            let term = String(text[open.upperBound..<close.lowerBound])
            if !term.isEmpty { terms.append(term) }
            cursor = close.upperBound
        }
        return terms
    }
}

public struct MasteryRecord: Equatable, Sendable {
    public var status: String?
    public var level: String?
    public var box: Int?
    public var ease: Double?
    public var due: String?
    public var nextReview: String?
}

public enum MasteryBadge: String, Equatable, Sendable {
    case notStarted
    case learning
    case known
    case due
}

public enum MasteryFile {
    public static func parse(_ text: String) -> [String: MasteryRecord] {
        guard let root = JSONValue.parse(text)?.object else { return [:] }
        var records: [String: MasteryRecord] = [:]
        for (key, value) in root {
            records[key] = record(value)
        }
        return records
    }

    public static func badge(_ record: MasteryRecord?) -> MasteryBadge {
        guard let record else { return .notStarted }
        let status = (record.status ?? record.level ?? "").lowercased()
        if status.contains("master") || status.contains("known") || (record.box ?? 0) >= 5 { return .known }
        if record.due != nil || record.nextReview != nil || status.contains("due") { return .due }
        if record.status != nil || record.level != nil || record.box != nil || record.ease != nil { return .learning }
        return .notStarted
    }

    private static func record(_ value: JSONValue) -> MasteryRecord {
        if let text = value.string {
            return MasteryRecord(status: text, level: nil, box: nil, ease: nil, due: nil, nextReview: nil)
        }
        if let number = value.int {
            return MasteryRecord(status: nil, level: String(number), box: number, ease: nil, due: nil, nextReview: nil)
        }
        let object = value.object ?? [:]
        return MasteryRecord(
            status: object["status"]?.string,
            level: object["level"]?.string ?? object["level"]?.int.map(String.init),
            box: object["box"]?.int,
            ease: object["ease"]?.double,
            due: object["due"]?.string,
            nextReview: object["next_review"]?.string ?? object["nextReview"]?.string
        )
    }
}
