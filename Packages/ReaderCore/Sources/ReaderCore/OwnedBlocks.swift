import Foundation

/// Reader's slices of a hand-written Markdown file. User text outside the markers
/// is copied through unchanged.
public enum OwnedBlocks {
    public struct Piece: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case user
            case owned(id: String)
        }

        public var kind: Kind
        public var body: String
        public var raw: String

        public init(kind: Kind, body: String, raw: String) {
            self.kind = kind
            self.body = body
            self.raw = raw
        }

        public var id: String? {
            if case .owned(let id) = kind { return id }
            return nil
        }
    }

    public static func render(id: String, body: String) -> String {
        "<!-- reader:begin id=\(id) -->\n\(body)\n<!-- reader:end -->"
    }

    public static func parse(_ text: String) -> [Piece] {
        let beginToken = "<!-- reader:begin id="
        let endToken = "<!-- reader:end -->"
        var pieces: [Piece] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let begin = text.range(of: beginToken, range: cursor..<text.endIndex) else {
                let raw = String(text[cursor..<text.endIndex])
                if !raw.isEmpty { pieces.append(Piece(kind: .user, body: raw, raw: raw)) }
                break
            }
            if begin.lowerBound > cursor {
                let raw = String(text[cursor..<begin.lowerBound])
                pieces.append(Piece(kind: .user, body: raw, raw: raw))
            }
            let idStart = begin.upperBound
            guard let idEnd = text.range(of: " -->", range: idStart..<text.endIndex) else {
                let raw = String(text[begin.lowerBound..<text.endIndex])
                pieces.append(Piece(kind: .user, body: raw, raw: raw))
                break
            }
            let id = String(text[idStart..<idEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
            let contentStart = idEnd.upperBound
            guard let end = text.range(of: endToken, range: contentStart..<text.endIndex) else {
                let raw = String(text[begin.lowerBound..<text.endIndex])
                pieces.append(Piece(kind: .user, body: raw, raw: raw))
                break
            }
            var body = String(text[contentStart..<end.lowerBound])
            if body.hasPrefix("\n") { body.removeFirst() }
            if body.hasSuffix("\n") { body.removeLast() }
            let raw = String(text[begin.lowerBound..<end.upperBound])
            pieces.append(Piece(kind: .owned(id: id), body: body, raw: raw))
            cursor = end.upperBound
        }
        return pieces
    }

    public static func body(id: String, in text: String) -> String? {
        parse(text).first { $0.id == id }?.body
    }

    /// Inserts or replaces one Reader block. Every user slice stays byte-for-byte.
    public static func upsert(_ text: String, id: String, body: String) -> String {
        let pieces = parse(text)
        let rendered = render(id: id, body: body)
        if let index = pieces.firstIndex(where: { $0.id == id }) {
            var copy = pieces
            copy[index] = Piece(kind: .owned(id: id), body: body, raw: rendered)
            return copy.map(\.raw).joined()
        }
        if text.isEmpty { return rendered + "\n" }
        let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
        return text + separator + rendered + "\n"
    }

    public static func remove(_ text: String, id: String) -> String {
        let pieces = parse(text).filter { $0.id != id }
        return pieces.map(\.raw).joined()
    }
}
