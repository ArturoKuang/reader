import Foundation

public struct EPUBSpineItem: Equatable, Sendable {
    public var id: String
    public var href: String
    public var mediaType: String
    public var title: String

    public init(id: String, href: String, mediaType: String, title: String) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.title = title
    }
}

public struct EPUBTOCItem: Equatable, Sendable {
    public var title: String
    public var href: String
    public var depth: Int

    public init(title: String, href: String, depth: Int) {
        self.title = title
        self.href = href
        self.depth = depth
    }
}

public struct EPUBBook: Equatable, Sendable {
    public var title: String
    public var identifier: String
    public var creator: String?
    public var root: String
    public var spine: [EPUBSpineItem]
    public var toc: [EPUBTOCItem]
    public var files: [String: Data]

    public init(data: Data) throws {
        let entries = try ZipArchive.read(data)
        var files: [String: Data] = [:]
        for entry in entries where !entry.name.hasSuffix("/") {
            files[entry.name] = entry.data
        }
        guard let container = files["META-INF/container.xml"].flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw ReaderFailure("The EPUB has no META-INF/container.xml.")
        }
        guard let opfPath = XML.firstAttribute("full-path", in: container) else {
            throw ReaderFailure("The EPUB container has no root file.")
        }
        guard let opfData = files[opfPath], let opf = String(data: opfData, encoding: .utf8) else {
            throw ReaderFailure("The EPUB package \(opfPath) is missing.")
        }
        let root = Paths.parent(opfPath)
        let prefix = root == "." || root == "/" ? "" : root + "/"
        let metadata = XML.inner(of: "metadata", in: opf) ?? opf
        let title = XML.text(of: "dc:title", in: metadata) ?? Paths.stem(opfPath)
        let identifier = XML.text(of: "dc:identifier", in: metadata) ?? ""
        let creator = XML.text(of: "dc:creator", in: metadata)
        var manifest: [String: (href: String, type: String, properties: String)] = [:]
        for element in XML.elements(named: "item", in: opf) {
            guard let id = element.attributes["id"], let href = element.attributes["href"] else { continue }
            manifest[id] = (
                href: XML.decode(href),
                type: element.attributes["media-type"] ?? "",
                properties: element.attributes["properties"] ?? ""
            )
        }
        var spineIDs: [String] = []
        for element in XML.elements(named: "itemref", in: opf) {
            if let id = element.attributes["idref"] { spineIDs.append(id) }
        }
        let toc = Self.tableOfContents(opf: opf, manifest: manifest, files: files, prefix: prefix)
        var titles: [String: String] = [:]
        for item in toc {
            let bare = item.href.split(separator: "#").first.map(String.init) ?? item.href
            if titles[bare] == nil { titles[bare] = item.title }
        }
        let spine = spineIDs.compactMap { id -> EPUBSpineItem? in
            guard let item = manifest[id] else { return nil }
            return EPUBSpineItem(id: id, href: item.href, mediaType: item.type, title: titles[item.href] ?? item.href)
        }
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.creator = creator
        self.root = prefix
        self.spine = spine
        self.toc = toc
        self.files = files
    }

    public func data(for href: String) -> Data? {
        let path = root.isEmpty ? href : root + href
        return files[path] ?? files[href]
    }

    public func xhtml(for href: String) -> String? {
        guard let data = data(for: href) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func bookText() -> BookText {
        var pages: [BookPage] = []
        for (index, item) in spine.enumerated() {
            let text = xhtml(for: item.href).map(XHTMLText.plain) ?? ""
            pages.append(BookPage(
                marker: item.title.isEmpty ? "Section \(index + 1)" : item.title,
                section: item.title,
                text: text,
                page: nil,
                spineIndex: index
            ))
        }
        return BookText(title: title, pages: pages)
    }

    public func textCorpus() -> TextCorpus {
        TextCorpus(slices: bookText().pages.map {
            TextSlice(page: nil, spineIndex: $0.spineIndex, section: $0.section, text: $0.text)
        })
    }

    private static func tableOfContents(
        opf: String,
        manifest: [String: (href: String, type: String, properties: String)],
        files: [String: Data],
        prefix: String
    ) -> [EPUBTOCItem] {
        if let nav = manifest.first(where: { $0.value.properties.split(separator: " ").contains("nav") }) {
            let path = prefix + nav.value.href
            if let html = files[path].flatMap({ String(data: $0, encoding: .utf8) }) {
                let items = navTOC(html)
                if !items.isEmpty { return items }
            }
        }
        if let ncx = manifest.first(where: { $0.value.type == "application/x-dtbncx+xml" }) {
            let path = prefix + ncx.value.href
            if let xml = files[path].flatMap({ String(data: $0, encoding: .utf8) }) {
                return ncxTOC(xml)
            }
        }
        return []
    }

    private static func navTOC(_ html: String) -> [EPUBTOCItem] {
        let nav = XML.inner(of: "nav", in: html) ?? html
        return XML.elements(named: "a", in: nav).compactMap { element in
            guard let href = element.attributes["href"] else { return nil }
            let title = XHTMLText.plain(element.inner).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return EPUBTOCItem(title: title, href: XML.decode(href), depth: 0)
        }
    }

    private static func ncxTOC(_ xml: String) -> [EPUBTOCItem] {
        XML.elements(named: "navPoint", in: xml).compactMap { point in
            let title = XML.text(of: "text", in: point.inner)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let href = XML.elements(named: "content", in: point.inner).first?.attributes["src"] ?? ""
            guard !title.isEmpty, !href.isEmpty else { return nil }
            return EPUBTOCItem(title: title, href: XML.decode(href), depth: 0)
        }
    }
}

public enum XHTMLText {
    public static func plain(_ xhtml: String) -> String {
        var source = xhtml
        source = drop(tag: "script", in: source)
        source = drop(tag: "style", in: source)
        var text = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "<" {
                let rest = source[index...]
                let name = tagName(rest)
                if let close = rest.firstIndex(of: ">") {
                    let block = ["p", "div", "h1", "h2", "h3", "h4", "li", "br", "tr", "section", "blockquote"].contains(name)
                    if block && !text.hasSuffix("\n") { text.append("\n") }
                    index = source.index(after: close)
                    continue
                }
            }
            text.append(source[index])
            index = source.index(after: index)
        }
        let decoded = XML.decode(text)
        let lines = decoded.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func drop(tag: String, in source: String) -> String {
        var output = ""
        var cursor = source.startIndex
        let open = "<\(tag)"
        let close = "</\(tag)>"
        while cursor < source.endIndex {
            let slice = source[cursor...]
            guard let start = slice.range(of: open, options: [.caseInsensitive])?.lowerBound else {
                output += slice
                break
            }
            output += source[cursor..<start]
            if let end = source.range(of: close, options: [.caseInsensitive], range: start..<source.endIndex)?.upperBound {
                cursor = end
            } else {
                break
            }
        }
        return output
    }

    private static func tagName(_ slice: Substring) -> String {
        var index = slice.index(after: slice.startIndex)
        if index < slice.endIndex, slice[index] == "/" { index = slice.index(after: index) }
        var name = ""
        while index < slice.endIndex {
            let character = slice[index]
            if character == " " || character == ">" || character == "/" || character == "\n" { break }
            name.append(character)
            index = slice.index(after: index)
        }
        return name.lowercased()
    }
}

struct XMLElement {
    var name: String
    var attributes: [String: String]
    var inner: String
}

enum XML {
    static func decode(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&" {
                let rest = text[index...]
                if let semi = rest.firstIndex(of: ";") {
                    let token = String(rest[rest.index(after: rest.startIndex)..<semi])
                    if let replacement = entity(token) {
                        output.append(replacement)
                        index = text.index(after: semi)
                        continue
                    }
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    static func firstAttribute(_ name: String, in xml: String) -> String? {
        elements(named: "rootfile", in: xml).first?.attributes[name]
            ?? elements(allIn: xml).first { $0.attributes[name] != nil }?.attributes[name]
    }

    static func text(of name: String, in xml: String) -> String? {
        guard let element = elements(named: name, in: xml).first else { return nil }
        let value = plainText(element.inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func inner(of name: String, in xml: String) -> String? {
        elements(named: name, in: xml).first?.inner
    }

    static func elements(named name: String, in xml: String) -> [XMLElement] {
        var found: [XMLElement] = []
        func walk(_ source: String) {
            for element in elements(allIn: source) {
                if element.name == name || element.name.hasSuffix(":" + name) {
                    found.append(element)
                }
                if !element.inner.isEmpty {
                    walk(element.inner)
                }
            }
        }
        walk(xml)
        return found
    }

    static func elements(allIn xml: String) -> [XMLElement] {
        var found: [XMLElement] = []
        var index = xml.startIndex
        while index < xml.endIndex {
            guard let open = xml[index...].firstIndex(of: "<") else { break }
            let next = xml.index(after: open)
            if next >= xml.endIndex { break }
            let mark = xml[next]
            if mark == "/" || mark == "!" || mark == "?" {
                if let close = xml[open...].firstIndex(of: ">") {
                    index = xml.index(after: close)
                    continue
                }
                break
            }
            guard let close = xml[open...].firstIndex(of: ">") else { break }
            let header = String(xml[next..<close])
            let selfClosing = header.hasSuffix("/")
            let (name, attributes) = parseTag(header)
            let after = xml.index(after: close)
            if selfClosing || name.isEmpty {
                if !name.isEmpty {
                    found.append(XMLElement(name: name, attributes: attributes, inner: ""))
                }
                index = after
                continue
            }
            if let end = matchingClose(name, from: after, in: xml) {
                let inner = String(xml[after..<end.start])
                found.append(XMLElement(name: name, attributes: attributes, inner: inner))
                index = end.end
            } else {
                index = after
            }
        }
        return found
    }

    private static func matchingClose(_ name: String, from start: String.Index, in xml: String) -> (start: String.Index, end: String.Index)? {
        let openToken = "<" + name
        let closeToken = "</" + name
        var depth = 1
        var cursor = start
        while cursor < xml.endIndex {
            let slice = xml[cursor...]
            let nextOpen = slice.range(of: openToken)?.lowerBound
            let nextClose = slice.range(of: closeToken)?.lowerBound
            if let nextClose, nextOpen == nil || nextClose < nextOpen! {
                depth -= 1
                guard let end = xml[nextClose...].firstIndex(of: ">") else { return nil }
                if depth == 0 { return (nextClose, xml.index(after: end)) }
                cursor = xml.index(after: end)
            } else if let nextOpen {
                let afterName = xml.index(nextOpen, offsetBy: openToken.count, limitedBy: xml.endIndex) ?? xml.endIndex
                if afterName < xml.endIndex {
                    let boundary = xml[afterName]
                    if boundary.isLetter || boundary == ":" || boundary == "-" { 
                        cursor = afterName
                        continue
                    }
                }
                depth += 1
                guard let end = xml[nextOpen...].firstIndex(of: ">") else { return nil }
                cursor = xml.index(after: end)
            } else {
                return nil
            }
        }
        return nil
    }

    private static func parseTag(_ header: String) -> (String, [String: String]) {
        var cleaned = header
        if cleaned.hasSuffix("/") { cleaned.removeLast() }
        let parts = cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
        guard let name = parts.first else { return ("", [:]) }
        var attributes: [String: String] = [:]
        let rest = cleaned.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        var cursor = rest.startIndex
        while cursor < rest.endIndex {
            while cursor < rest.endIndex, rest[cursor].isWhitespace { cursor = rest.index(after: cursor) }
            guard cursor < rest.endIndex else { break }
            var key = ""
            while cursor < rest.endIndex, rest[cursor] != "=" && !rest[cursor].isWhitespace {
                key.append(rest[cursor])
                cursor = rest.index(after: cursor)
            }
            while cursor < rest.endIndex, rest[cursor].isWhitespace { cursor = rest.index(after: cursor) }
            guard cursor < rest.endIndex, rest[cursor] == "=" else { break }
            cursor = rest.index(after: cursor)
            while cursor < rest.endIndex, rest[cursor].isWhitespace { cursor = rest.index(after: cursor) }
            guard cursor < rest.endIndex else { break }
            let quote = rest[cursor]
            if quote == "\"" || quote == "'" {
                cursor = rest.index(after: cursor)
                var value = ""
                while cursor < rest.endIndex, rest[cursor] != quote {
                    value.append(rest[cursor])
                    cursor = rest.index(after: cursor)
                }
                if cursor < rest.endIndex { cursor = rest.index(after: cursor) }
                attributes[key] = decode(value)
            } else {
                break
            }
        }
        return (name, attributes)
    }

    private static func plainText(_ xml: String) -> String {
        var output = ""
        var inTag = false
        for character in xml {
            if character == "<" { inTag = true; continue }
            if character == ">" { inTag = false; continue }
            if !inTag { output.append(character) }
        }
        return decode(output)
    }

    private static func entity(_ token: String) -> String? {
        switch token {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            if token.hasPrefix("#x"), let value = UInt32(token.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
                return String(Character(scalar))
            }
            if token.hasPrefix("#"), let value = UInt32(token.dropFirst()), let scalar = Unicode.Scalar(value) {
                return String(Character(scalar))
            }
            return nil
        }
    }
}
