import Foundation

public struct ReaderLink: Equatable, Sendable {
    public var path: String
    public var location: String?
    public var id: String?

    public init(path: String, location: String? = nil, id: String? = nil) {
        self.path = path
        self.location = location
        self.id = id
    }

    public var url: String {
        var items = ["path=\(Query.escape(path))"]
        if let location, !location.isEmpty { items.append("loc=\(Query.escape(location))") }
        if let id, !id.isEmpty { items.append("id=\(Query.escape(id))") }
        return "reader://open?\(items.joined(separator: "&"))"
    }

    public var markdown: String {
        "[↗ Open in Reader](\(url))"
    }

    public static func parse(_ raw: String) -> ReaderLink? {
        guard let scheme = raw.range(of: "reader://open?") else { return nil }
        let query = String(raw[scheme.upperBound...]).split(separator: "#").first.map(String.init) ?? ""
        var path: String?
        var location: String?
        var id: String?
        for part in query.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = Query.unescape(pair[1])
            switch pair[0] {
            case "path": path = value
            case "loc": location = value
            case "id": id = value
            default: break
            }
        }
        guard let path, !path.isEmpty else { return nil }
        return ReaderLink(path: path, location: location, id: id)
    }

    /// `page=4` or `page=4&y=120` from a PDF deep link. EPUB locations stay CFIs.
    public var pageNumber: Int? {
        guard let location, !location.hasPrefix("epubcfi(") else { return nil }
        for part in location.split(whereSeparator: { $0 == "&" || $0 == ";" }) {
            let piece = String(part)
            if piece.hasPrefix("page="), let number = Int(piece.dropFirst("page=".count)) { return number }
        }
        return nil
    }
}

public enum ObsidianLink {
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
}
