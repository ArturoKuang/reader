import Foundation

public struct MarkdownFrontMatter: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: String
        public var items: [String]
    }
    public var rawYAML: String
    public var fields: [Field]
    public var title: String?
    public var tags: [String]
}

public struct MarkdownHeading: Equatable, Sendable, Identifiable {
    public var id: String
    public var level: Int
    public var title: String
    public var sourceLine: Int
    public var sectionIndex: Int
}

public struct MarkdownWikiLink: Equatable, Sendable {
    public var target: String
    public var heading: String?
    public var alias: String?
    public var isEmbed: Bool

    public var displayText: String {
        if let alias, !alias.isEmpty { return alias }
        guard let heading else { return target }
        return target.isEmpty ? heading : "\(target) > \(heading)"
    }
}

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link([MarkdownInline], url: String, title: String?)
    case image(alt: String, url: String, title: String?)
    case wikilink(MarkdownWikiLink)
    case math(String, display: Bool)
    case footnoteReference(String)
    case softBreak
    case lineBreak

    public var plainText: String {
        switch self {
        case .text(let value), .code(let value): return value
        case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(let children, _, _):
            return children.plainText
        case .image(let alt, _, _): return alt
        case .wikilink(let link): return link.isEmbed ? "" : link.displayText
        case .math(let tex, let display): return LaTeXMathRenderer.render(tex, display: display).spokenText
        case .footnoteReference: return ""
        case .softBreak: return " "
        case .lineBreak: return "\n"
        }
    }
}

extension Array where Element == MarkdownInline {
    public var plainText: String { map(\.plainText).joined() }
}

public enum MarkdownColumnAlignment: Equatable, Sendable {
    case none, left, center, right
}

public enum MarkdownCalloutFold: Equatable, Sendable {
    case fixed, collapsed, expanded
}

public struct MarkdownListItem: Equatable, Sendable {
    /// nil for an ordinary item; true or false for a task item.
    public var task: Bool?
    public var blocks: [MarkdownBlock]
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, id: String, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case blockquote([MarkdownBlock])
    case callout(type: String, title: [MarkdownInline], fold: MarkdownCalloutFold, blocks: [MarkdownBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [MarkdownListItem])
    case table(alignments: [MarkdownColumnAlignment], header: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case code(language: String?, text: String)
    case math(String)
    case thematicBreak

    public var plainText: String {
        switch self {
        case .heading(_, _, let content), .paragraph(let content): return content.plainText
        case .blockquote(let blocks): return blocks.plainText
        case .callout(_, let title, _, let blocks):
            return [title.plainText, blocks.plainText].filter { !$0.isEmpty }.joined(separator: "\n")
        case .list(_, _, _, let items): return items.map { $0.blocks.plainText }.joined(separator: "\n")
        case .table(_, let header, let rows):
            return ([header] + rows).map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
        case .code(_, let text): return text
        case .math(let tex): return LaTeXMathRenderer.render(tex, display: true).spokenText
        case .thematicBreak: return ""
        }
    }
}

extension Array where Element == MarkdownBlock {
    public var plainText: String { map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n") }
}

public struct MarkdownSection: Equatable, Sendable, Identifiable {
    public var id: String { anchorID }
    public var index: Int
    public var anchorID: String
    public var title: String
    public var level: Int
    public var blocks: [MarkdownBlock]
    public var plainText: String
}

/// `mdloc(s=2,a=architecture,o=14,e=52)`.
public struct MarkdownAnchor: Equatable, Sendable {
    public var sectionIndex: Int
    public var anchorID: String
    public var startOffset: Int?
    public var endOffset: Int?
    public var rawValue: String

    public init?(value: String) {
        // The first ")" ends the anchor; a trailing `&quote=` may contain more.
        guard value.hasPrefix("mdloc("), let close = value.firstIndex(of: ")") else { return nil }
        let body = value[value.index(value.startIndex, offsetBy: 6)..<close]
        var fields: [String: String] = [:]
        for part in body.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            fields[String(pair[0])] = String(pair[1])
        }
        guard let section = fields["s"].flatMap({ Int($0) }), section >= 0, let anchor = fields["a"] else { return nil }
        sectionIndex = section
        anchorID = anchor
        startOffset = fields["o"].flatMap { Int($0) }
        endOffset = fields["e"].flatMap { Int($0) }
        rawValue = String(value[...close])
    }

    public static func make(sectionIndex: Int, anchorID: String, start: Int? = nil, end: Int? = nil) -> MarkdownAnchor {
        var raw = "mdloc(s=\(sectionIndex),a=\(anchorID)"
        if let start { raw += ",o=\(start)" }
        if let end { raw += ",e=\(end)" }
        raw += ")"
        return MarkdownAnchor(sectionIndex: sectionIndex, anchorID: anchorID, startOffset: start, endOffset: end, rawValue: raw)
    }

    private init(sectionIndex: Int, anchorID: String, startOffset: Int?, endOffset: Int?, rawValue: String) {
        self.sectionIndex = sectionIndex
        self.anchorID = anchorID
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.rawValue = rawValue
    }
}

public struct MarkdownDocumentModel: Equatable, Sendable {
    public var title: String
    public var frontMatter: MarkdownFrontMatter?
    public var headings: [MarkdownHeading]
    public var sections: [MarkdownSection]
    public var footnotes: [String: [MarkdownBlock]]
    public var wikilinks: [MarkdownWikiLink]

    public static func parse(source: String, fileName: String) -> MarkdownDocumentModel {
        MarkdownParser.parse(source: source, fileName: fileName)
    }

    public func bookText() -> BookText {
        BookText(title: title, pages: sections.map {
            BookPage(marker: "section \($0.index + 1)", section: $0.title, text: $0.plainText)
        })
    }

    public func textCorpus() -> TextCorpus {
        TextCorpus(slices: sections.map {
            TextSlice(section: $0.title, text: $0.plainText, markdownSection: $0.index, anchorID: $0.anchorID)
        })
    }
}
