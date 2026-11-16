import Foundation

public struct TextSlice: Equatable, Sendable {
    public var page: Int?
    public var spineIndex: Int?
    public var section: String?
    public var text: String

    public init(page: Int? = nil, spineIndex: Int? = nil, section: String? = nil, text: String) {
        self.page = page
        self.spineIndex = spineIndex
        self.section = section
        self.text = text
    }
}

public struct TextCorpus: Equatable, Sendable {
    public var slices: [TextSlice]
    public init(slices: [TextSlice]) { self.slices = slices }
}

public struct ReanchorHit: Equatable, Sendable {
    public var page: Int?
    public var spineIndex: Int?
    public var section: String?
    public var prefix: String
    public var suffix: String
    public var cfi: String?
    public enum Confidence: String, Equatable, Sendable { case exactContext, quoteOnly }
    public var confidence: Confidence
}

public struct ReanchorReport: Equatable, Sendable {
    public var unresolvedIDs: [String]
    public init(unresolvedIDs: [String]) { self.unresolvedIDs = unresolvedIDs }
}

public enum Reanchorer {
    public static func locate(quote: String, prefix: String, suffix: String, in corpus: TextCorpus) -> ReanchorHit? {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let hit = search(quote: needle, prefix: prefix, suffix: suffix, corpus: corpus, requireContext: true) {
            return hit
        }
        return search(quote: needle, prefix: prefix, suffix: suffix, corpus: corpus, requireContext: false)
    }

    public static func apply(package: inout SidecarPackage, corpus: TextCorpus) -> ReanchorReport {
        var unresolved: [String] = []
        for index in package.notes.notes.indices {
            let note = package.notes.notes[index]
            if let hit = locate(quote: note.quote, prefix: note.prefix, suffix: note.suffix, in: corpus) {
                package.notes.notes[index].page = hit.page ?? note.page
                package.notes.notes[index].section = hit.section ?? note.section
                package.notes.notes[index].prefix = hit.prefix
                package.notes.notes[index].suffix = hit.suffix
                if let cfi = hit.cfi { package.notes.notes[index].cfi = cfi }
            } else {
                unresolved.append(note.id)
            }
        }
        for index in package.highlights.highlights.indices {
            let highlight = package.highlights.highlights[index]
            if let hit = locate(quote: highlight.quote, prefix: highlight.prefix, suffix: highlight.suffix, in: corpus) {
                package.highlights.highlights[index].page = hit.page ?? highlight.page
                package.highlights.highlights[index].section = hit.section ?? highlight.section
                package.highlights.highlights[index].prefix = hit.prefix
                package.highlights.highlights[index].suffix = hit.suffix
                if let cfi = hit.cfi { package.highlights.highlights[index].cfi = cfi }
            } else {
                unresolved.append(highlight.id)
            }
        }
        for wordIndex in package.words.words.indices {
            for lookupIndex in package.words.words[wordIndex].lookups.indices {
                let lookup = package.words.words[wordIndex].lookups[lookupIndex]
                let quote = lookup.quote.isEmpty ? package.words.words[wordIndex].word : lookup.quote
                if let hit = locate(quote: quote, prefix: lookup.prefix, suffix: lookup.suffix, in: corpus) {
                    package.words.words[wordIndex].lookups[lookupIndex].page = hit.page ?? lookup.page
                    package.words.words[wordIndex].lookups[lookupIndex].section = hit.section ?? lookup.section
                    package.words.words[wordIndex].lookups[lookupIndex].prefix = hit.prefix
                    package.words.words[wordIndex].lookups[lookupIndex].suffix = hit.suffix
                    if let cfi = hit.cfi { package.words.words[wordIndex].lookups[lookupIndex].cfi = cfi }
                } else {
                    unresolved.append(lookup.id)
                }
            }
        }
        for index in package.marks.marks.indices {
            guard let quote = package.marks.marks[index].position.quote, !quote.isEmpty else { continue }
            let position = package.marks.marks[index].position
            if let hit = locate(quote: quote, prefix: position.prefix ?? "", suffix: position.suffix ?? "", in: corpus) {
                package.marks.marks[index].position.page = hit.page ?? position.page
                package.marks.marks[index].position.section = hit.section ?? position.section
                package.marks.marks[index].position.prefix = hit.prefix
                package.marks.marks[index].position.suffix = hit.suffix
                if let cfi = hit.cfi { package.marks.marks[index].position.cfi = cfi }
            } else {
                unresolved.append(package.marks.marks[index].id)
            }
        }
        return ReanchorReport(unresolvedIDs: unresolved)
    }

    private static func search(quote: String, prefix: String, suffix: String, corpus: TextCorpus, requireContext: Bool) -> ReanchorHit? {
        for slice in corpus.slices {
            let text = slice.text
            var search = text.startIndex
            while let range = text.range(of: quote, range: search..<text.endIndex) {
                let before = String(text[text.startIndex..<range.lowerBound])
                let after = String(text[range.upperBound..<text.endIndex])
                let prefixOK = prefix.isEmpty || before.hasSuffix(prefix)
                let suffixOK = suffix.isEmpty || after.hasPrefix(suffix)
                if requireContext {
                    if prefixOK && suffixOK && (!prefix.isEmpty || !suffix.isEmpty) {
                        return hit(slice: slice, quote: quote, before: before, after: after, confidence: .exactContext)
                    }
                } else if prefix.isEmpty && suffix.isEmpty || !prefixOK || !suffixOK {
                    if prefix.isEmpty && suffix.isEmpty || !requireContext {
                        return hit(slice: slice, quote: quote, before: before, after: after, confidence: .quoteOnly)
                    }
                }
                search = range.upperBound
            }
        }
        return nil
    }

    private static func hit(slice: TextSlice, quote: String, before: String, after: String, confidence: ReanchorHit.Confidence) -> ReanchorHit {
        let prefix = String(before.suffix(80))
        let suffix = String(after.prefix(80))
        var cfi: String?
        if let spine = slice.spineIndex {
            let start = before.count
            cfi = EPUBCFI.make(spineIndex: spine, start: start, end: start + quote.count).value
        }
        return ReanchorHit(
            page: slice.page,
            spineIndex: slice.spineIndex,
            section: slice.section,
            prefix: prefix,
            suffix: suffix,
            cfi: cfi,
            confidence: confidence
        )
    }
}
