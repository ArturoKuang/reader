import Foundation

public struct HighlightPaintMark: Equatable, Sendable {
    public var quote: String
    public var color: Int
    public var prefix: String
    public var suffix: String
    public var chapter: Int?
    public var spineIndex: Int?

    public init(quote: String, color: Int, prefix: String, suffix: String, chapter: Int? = nil, spineIndex: Int? = nil) {
        self.quote = quote
        self.color = color
        self.prefix = prefix
        self.suffix = suffix
        self.chapter = chapter
        self.spineIndex = spineIndex
    }
}

public enum HighlightPaint {
    /// One paint instruction per highlight. The spine index comes from the CFI; the chapter comes from the section title.
    public static func marks(for highlights: [HighlightEntry]) -> [HighlightPaintMark] {
        highlights.compactMap { highlight in
            guard !highlight.quote.isEmpty else { return nil }
            return HighlightPaintMark(
                quote: highlight.quote,
                color: highlight.color,
                prefix: highlight.prefix,
                suffix: highlight.suffix,
                chapter: highlight.section.flatMap { ChapterFiles.number(in: $0) },
                spineIndex: highlight.cfi.flatMap { EPUBCFI(value: $0)?.spineIndex }
            )
        }
    }

    /// The copy of `mark.quote` that belongs to this highlight.
    /// A CFI spine index must match when the record has one; otherwise the chapter must.
    /// Prefix and suffix have to sit against that copy, so a repeated phrase in another chapter is left alone.
    public static func occurrence(of mark: HighlightPaintMark, in text: String, chapter: Int?, spineIndex: Int?) -> Range<String.Index>? {
        if let wanted = mark.spineIndex {
            guard spineIndex == wanted else { return nil }
        } else if let wanted = mark.chapter {
            guard chapter == wanted else { return nil }
        }
        var search = text.startIndex
        while let range = text.range(of: mark.quote, range: search..<text.endIndex) {
            let before = text[..<range.lowerBound]
            let after = text[range.upperBound...]
            let prefixOK = mark.prefix.isEmpty || before.hasSuffix(mark.prefix)
            let suffixOK = mark.suffix.isEmpty || after.hasPrefix(mark.suffix)
            if prefixOK && suffixOK { return range }
            search = range.upperBound
        }
        return nil
    }
}
