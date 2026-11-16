import Foundation

public enum HighlightCallout {
    public static func name(for color: Int) -> String {
        switch color {
        case 1: return "yellow"
        case 2: return "green"
        case 3: return "blue"
        case 4: return "pink"
        case 5: return "purple"
        case 6: return "orange"
        default: return "yellow"
        }
    }

    public static func color(named name: String) -> Int? {
        switch name.lowercased() {
        case "yellow": return 1
        case "green": return 2
        case "blue": return 3
        case "pink": return 4
        case "purple": return 5
        case "orange": return 6
        default: return nil
        }
    }
}

public struct VaultNoteBlock: Equatable, Sendable {
    public var id: String
    public var quote: String
    public var body: String
    public var color: Int?
    public var link: ReaderLink
    public var chapter: Int?

    public init(id: String, quote: String, body: String, color: Int? = nil, link: ReaderLink, chapter: Int? = nil) {
        self.id = id
        self.quote = quote
        self.body = body
        self.color = color
        self.link = link
        self.chapter = chapter
    }

    public func markdown() -> String {
        var lines: [String] = []
        if let color {
            lines.append("> [!quote] \(HighlightCallout.name(for: color))")
            for line in quote.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
        } else if !quote.isEmpty {
            for line in quote.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
        }
        if !body.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(body)
        }
        lines.append("")
        lines.append(link.markdown)
        lines.append("")
        lines.append("^\(id)")
        return lines.joined(separator: "\n")
    }
}

public enum VaultNoteFile {
    public static func upsert(_ text: String, block: VaultNoteBlock) -> String {
        OwnedBlocks.upsert(text, id: block.id, body: block.markdown())
    }

    public static func remove(_ text: String, id: String) -> String {
        OwnedBlocks.remove(text, id: id)
    }

    public static func blocks(_ text: String) -> [VaultNoteBlock] {
        OwnedBlocks.parse(text).compactMap { piece in
            guard let id = piece.id else { return nil }
            return parseBody(id: id, body: piece.body)
        }
    }

    static func parseBody(id: String, body: String) -> VaultNoteBlock {
        var color: Int?
        var quoteLines: [String] = []
        var prose: [String] = []
        var link = ReaderLink(path: "", id: id)
        var inQuote = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("> [!quote]") {
                let name = line.dropFirst("> [!quote]".count).trimmingCharacters(in: .whitespaces)
                color = HighlightCallout.color(named: name)
                inQuote = true
                continue
            }
            if line.hasPrefix(">") {
                var text = String(line.dropFirst())
                if text.hasPrefix(" ") { text.removeFirst() }
                quoteLines.append(text)
                inQuote = true
                continue
            }
            if line.hasPrefix("[↗ Open in Reader]("), let urlStart = line.firstIndex(of: "("), let urlEnd = line.lastIndex(of: ")"), urlStart < urlEnd {
                let url = String(line[line.index(after: urlStart)..<urlEnd])
                if let parsed = ReaderLink.parse(url) { link = parsed }
                inQuote = false
                continue
            }
            if line.hasPrefix("^") { continue }
            if line.isEmpty && inQuote {
                inQuote = false
                continue
            }
            prose.append(line)
        }
        while prose.last?.isEmpty == true { prose.removeLast() }
        return VaultNoteBlock(id: id, quote: quoteLines.joined(separator: "\n"), body: prose.joined(separator: "\n"), color: color, link: link)
    }
}
