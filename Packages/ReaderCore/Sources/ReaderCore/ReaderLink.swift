import Foundation

public struct ReaderLink: Equatable, Sendable {
    public var path: String
    public var location: String?
    public var id: String?
    /// Book fingerprint from a top-level `fp=` parameter. A numeric `fp` inside `loc` is a scroll fraction instead.
    public var fingerprint: String?

    public init(path: String, location: String? = nil, id: String? = nil, fingerprint: String? = nil) {
        self.path = path
        self.location = location
        self.id = id
        self.fingerprint = fingerprint
    }

    public var url: String {
        var items = ["path=\(Query.escape(path))"]
        if let location, !location.isEmpty { items.append("loc=\(Query.escape(location))") }
        if let id, !id.isEmpty { items.append("id=\(Query.escape(id))") }
        if let fingerprint, !fingerprint.isEmpty { items.append("fp=\(Query.escape(fingerprint))") }
        return "reader://open?\(items.joined(separator: "&"))"
    }

    public var markdown: String {
        "[↗ Open in Reader](\(url))"
    }

    public static func parse(_ raw: String) -> ReaderLink? {
        let start = raw.range(of: "reader://open?") ?? raw.range(of: "reader://open/?")
        guard let start else { return nil }
        var query = String(raw[start.upperBound...]).split(separator: "#").first.map(String.init) ?? ""
        if query.hasPrefix("?") { query.removeFirst() }
        var path: String?
        var location: String?
        var id: String?
        var fingerprint: String?
        for part in query.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = Query.unescape(pair[1])
            switch pair[0] {
            case "path": path = value
            case "loc": location = value
            case "id": id = value
            case "fp": fingerprint = value
            default: break
            }
        }
        guard let path, !path.isEmpty else { return nil }
        var link = ReaderLink(path: path, location: location, id: id, fingerprint: fingerprint)
        if link.fingerprint == nil, let embedded = link.locationFields["fp"], Self.fraction(embedded) == nil {
            link.fingerprint = embedded
        }
        return link
    }

    /// Decoded pairs inside `loc` (`page`, `y`, `fp`). A still-encoded `page%3D3` counts.
    public var locationFields: [String: String] {
        guard let location, !location.isEmpty, !location.hasPrefix("epubcfi(") else { return [:] }
        let decoded = Query.unescapeDeep(location)
        var fields: [String: String] = [:]
        for part in decoded.split(whereSeparator: { $0 == "&" || $0 == ";" }) {
            var piece = String(part)
            if !piece.contains("=") {
                let again = Query.unescapeDeep(piece)
                if again.contains("=") { piece = again }
            }
            let pair = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            fields[pair[0]] = Query.unescape(pair[1])
        }
        return fields
    }

    /// `page=4` or `page=4&y=120` from a PDF deep link. EPUB locations stay CFIs.
    public var pageNumber: Int? {
        guard let page = locationFields["page"], let number = Int(page), number > 0 else { return nil }
        return number
    }

    /// `fp=0.25` is how far down the page to land. `fp=sha256:…` is not a scroll position.
    public var scrollFraction: Double? {
        if let raw = locationFields["fp"], let value = Self.fraction(raw) { return value }
        if let raw = fingerprint, let value = Self.fraction(raw) { return value }
        return nil
    }

    /// PDF user-space `y` from `loc`, when the link stored one.
    public var verticalOffset: Double? {
        guard let raw = locationFields["y"], let value = Double(raw) else { return nil }
        return value
    }

    private static func fraction(_ raw: String) -> Double? {
        guard raw.contains("."), let value = Double(raw), value >= 0, value <= 1 else { return nil }
        return value
    }
}

/// Where a `reader://` link should land in a PDF. The highlight id wins over `loc`.
public struct PDFJump: Equatable, Sendable {
    public var page: Int
    public var rects: [[Double]]
    public var quote: String?
    public var scrollY: Double?
    public var pdfY: Double?

    public init(page: Int, rects: [[Double]] = [], quote: String? = nil, scrollY: Double? = nil, pdfY: Double? = nil) {
        self.page = page
        self.rects = rects
        self.quote = quote
        self.scrollY = scrollY
        self.pdfY = pdfY
    }
}

public enum PDFJumpResolver {
    /// Find the highlight (or note) named by `id` and use its page and rects.
    /// Otherwise use `loc`'s page. A numeric `fp` becomes the scroll fraction.
    public static func resolve(link: ReaderLink, highlights: [HighlightEntry], notes: [NoteEntry]) -> PDFJump? {
        let scroll = link.scrollFraction
        let y = link.verticalOffset
        if let id = link.id, !id.isEmpty {
            if let highlight = highlights.first(where: { $0.id == id }) {
                if let page = highlight.page ?? link.pageNumber, page > 0 {
                    return PDFJump(page: page, rects: highlight.rects, quote: cleaned(highlight.quote), scrollY: scroll, pdfY: y)
                }
            }
            if let note = notes.first(where: { $0.id == id }) {
                if let page = note.page ?? link.pageNumber, page > 0 {
                    return PDFJump(page: page, rects: [], quote: cleaned(note.quote), scrollY: scroll, pdfY: y)
                }
            }
        }
        if let page = link.pageNumber, page > 0 {
            return PDFJump(page: page, rects: [], quote: nil, scrollY: scroll, pdfY: y)
        }
        return nil
    }

    private static func cleaned(_ quote: String) -> String? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum ObsidianLink {
    /// Vault-relative notes file, including the configured notes folder and `.md`.
    public static func noteFile(vaultRoot: String, bookFolder: String, notesFolder: String, chapter: Int?, bookTitle: String) -> String {
        var relative = bookFolder
        let root = vaultRoot.hasSuffix("/") ? String(vaultRoot.dropLast()) : vaultRoot
        if relative.hasPrefix(root) {
            relative = String(relative.dropFirst(root.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
        }
        let folder = notesFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = folder.isEmpty ? "notes" : folder
        return [relative, notes, ChapterFiles.notesFile(chapter: chapter, bookTitle: bookTitle)].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// Path shown in the inspector, relative to the vault root when it lives inside it.
    public static func displayPath(vaultRoot: String, absolute path: String) -> String {
        let root = vaultRoot.hasSuffix("/") ? String(vaultRoot.dropLast()) : vaultRoot
        var value = path
        if value.hasPrefix(root) {
            value = String(value.dropFirst(root.count))
            while value.hasPrefix("/") { value.removeFirst() }
        }
        return value
    }

    /// `file` is vault-relative and may include `.md`. A block id becomes `#^id`.
    public static func open(vault: String, file: String, blockID: String? = nil) -> String {
        var note = file
        if note.hasSuffix(".md") { note.removeLast(3) }
        if let blockID, !blockID.isEmpty {
            note += "#^\(blockID)"
        }
        return "obsidian://open?vault=\(Query.escape(vault))&file=\(Query.escape(note))"
    }
}

enum Query {
    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func unescape(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    /// One extra pass so `page%253D3` still becomes `page=3`.
    static func unescapeDeep(_ value: String) -> String {
        var current = value
        for _ in 0..<2 {
            guard let next = current.removingPercentEncoding, next != current else { break }
            current = next
        }
        return current
    }
}
