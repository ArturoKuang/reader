import Foundation

/// Offline CommonMark + GFM + Obsidian parser. Raw HTML is kept as literal text.
public enum MarkdownParser {
    public static func parse(source: String, fileName: String) -> MarkdownDocumentModel {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: "\n")
        var lineOffset = 0
        var frontMatter: MarkdownFrontMatter?
        if lines.first?.trimmed == "---",
           let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmed) }) {
            frontMatter = parseFrontMatter(lines[1..<end].map(expandingTabs))
            lineOffset = end + 1
            lines.removeFirst(end + 1)
        }
        var state = State()
        let top = state.blocks(lines, depth: 0)

        var sections: [MarkdownSection] = []
        var headings: [MarkdownHeading] = []
        var current: (anchor: String, title: String, level: Int, blocks: [MarkdownBlock]) = ("md-preamble", "", 0, [])
        func flush() {
            if current.level == 0 && current.blocks.isEmpty { return }
            sections.append(MarkdownSection(index: sections.count, anchorID: current.anchor, title: current.title,
                                            level: current.level, blocks: current.blocks, plainText: current.blocks.plainText))
        }
        for (block, line) in top {
            if case .heading(let level, let id, let content) = block {
                flush()
                let title = content.plainText.trimmed
                current = (id, title, level, [block])
                headings.append(MarkdownHeading(id: id, level: level, title: title, sourceLine: line + lineOffset + 1, sectionIndex: sections.count))
            } else {
                current.blocks.append(block)
            }
        }
        flush()
        let title = frontMatter?.title ?? headings.first(where: { $0.level == 1 })?.title ?? Paths.stem(fileName)
        if !sections.isEmpty, sections[0].level == 0 { sections[0].title = title }
        return MarkdownDocumentModel(title: title, frontMatter: frontMatter, headings: headings, sections: sections,
                                     footnotes: state.footnotes, wikilinks: state.wikilinks)
    }

    public static func slug(_ title: String) -> String {
        var result = ""
        for character in title.lowercased().trimmed {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                result.append(character)
            } else if character == " " {
                result.append("-")
            }
        }
        return result.isEmpty ? "section" : result
    }

    static func parseFrontMatter(_ lines: [String]) -> MarkdownFrontMatter {
        func unquote(_ raw: String) -> String {
            let value = raw.trimmed
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                return String(value.dropFirst().dropLast())
            }
            return value
        }
        var fields: [MarkdownFrontMatter.Field] = []
        for line in lines {
            let trimmed = line.trimmed
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !fields.isEmpty, trimmed == "-" || trimmed.hasPrefix("- ") {
                fields[fields.count - 1].items.append(unquote(String(trimmed.dropFirst())))
            } else if line.first != " ", let colon = trimmed.firstIndex(of: ":") {
                let key = unquote(String(trimmed[..<colon]))
                var value = String(trimmed[trimmed.index(after: colon)...]).trimmed
                var items: [String] = []
                if value.hasPrefix("["), value.hasSuffix("]") {
                    items = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }
                    value = ""
                } else if ["|", ">", "|-", ">-"].contains(value) {
                    value = ""
                }
                fields.append(.init(key: key, value: unquote(value), items: items))
            } else if !fields.isEmpty {
                fields[fields.count - 1].value = [fields[fields.count - 1].value, trimmed].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
        for index in fields.indices where !fields[index].items.isEmpty {
            fields[index].value = fields[index].items.joined(separator: ", ")
        }
        let title = fields.first { $0.key.lowercased() == "title" }?.value
        var tags: [String] = []
        if let field = fields.first(where: { ["tags", "tag"].contains($0.key.lowercased()) }) {
            tags = field.items.isEmpty ? field.value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) : field.items
        }
        return MarkdownFrontMatter(rawYAML: lines.joined(separator: "\n"), fields: fields,
                                   title: (title?.isEmpty ?? true) ? nil : title, tags: tags)
    }

    // MARK: - Block patterns

    static func match(_ line: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<result.numberOfRanges).map { Range(result.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
    }

    private static let atx = "^ {0,3}(#{1,6})(?:[ ]+(.*?))?[ ]*$"
    private static let fence = "^( {0,3})(`{3,}|~{3,})[ ]*([^`]*)$"
    private static let rule = "^ {0,3}([-*_])(?:[ ]*\\1){2,}[ ]*$"
    private static let marker = "^( {0,3})([-+*]|\\d{1,9}[.)])(?:( +)(.*))?$"
    private static let quote = "^ {0,3}> ?(.*)$"
    private static let footnote = "^ {0,3}\\[\\^([^\\]\\s]+)\\]:[ ]*(.*)$"
    private static let reference = "^ {0,3}\\[([^\\]^][^\\]]*)\\]:[ ]*<?([^\\s>]+)>?(?:[ ]+[\"'(](.*)[\"')])?[ ]*$"
    private static let delimiterRow = "^ {0,3}\\|?[ ]*:?-+:?[ ]*(\\|[ ]*:?-+:?[ ]*)*\\|?[ ]*$"

    private static func interrupts(_ line: String) -> Bool {
        if match(line, atx) != nil || match(line, fence) != nil || match(line, rule) != nil || match(line, quote) != nil { return true }
        if line.trimmed.hasPrefix("$$") { return true }
        if let item = match(line, marker), !item[4].isEmpty { return !item[2].first!.isNumber || item[2].hasPrefix("1") }
        return false
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    /// The form block patterns and prose are read from. Code keeps the original line.
    private static func expandingTabs(_ line: String) -> String { line.replacingOccurrences(of: "\t", with: "    ") }

    /// Removes up to `columns` of leading indentation, counting a tab as four. Tabs
    /// past that point stay; a tab cut partway leaves its remaining columns as spaces.
    private static func dedent(_ line: String, _ columns: Int) -> String {
        var rest = Substring(line)
        var left = columns
        while left > 0, let first = rest.first, first == " " || first == "\t" {
            rest.removeFirst()
            left -= first == "\t" ? 4 : 1
        }
        return String(repeating: " ", count: max(-left, 0)) + rest
    }

    private static func cells(_ line: String) -> [String] {
        var parts: [String] = [""]
        var escaped = false
        var wiki = 0
        var previous: Character = " "
        for character in line.trimmed {
            if character == "[" && previous == "[" { wiki += 1 }
            if character == "]" && previous == "]" { wiki = max(0, wiki - 1) }
            if character == "|" && !escaped && wiki == 0 {
                parts.append("")
            } else {
                if character == "|" && escaped { parts[parts.count - 1].removeLast() }
                parts[parts.count - 1].append(character)
            }
            escaped = character == "\\" && !escaped
            previous = character
        }
        if parts.first?.isEmpty == true { parts.removeFirst() }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map(\.trimmed)
    }

    // MARK: - Block parser

    private struct State {
        var slugs = Set<String>()
        var footnotes: [String: [MarkdownBlock]] = [:]
        var wikilinks: [MarkdownWikiLink] = []
        var references: [String: (String, String?)] = [:]

        mutating func inline(_ text: String) -> [MarkdownInline] {
            var parser = InlineParser(text: text, references: references)
            let result = parser.parse()
            wikilinks += parser.wikilinks
            return result
        }

        mutating func heading(_ level: Int, _ text: String) -> MarkdownBlock {
            let content = inline(text)
            let base = slug(content.plainText)
            var id = base
            var number = 1
            while slugs.contains(id) {
                id = "\(base)-\(number)"
                number += 1
            }
            slugs.insert(id)
            return .heading(level: level, id: id, content: content)
        }

        /// Returns each block with the index of its first line.
        mutating func blocks(_ input: [String], depth: Int) -> [(MarkdownBlock, Int)] {
            if depth > 24 { return [(.paragraph([.text(input.joined(separator: "\n"))]), 0)] }
            var lines = input
            if depth == 0 { collectReferences(&lines) }
            // `lines` keeps tabs for code and nested containers; `flat` is for matching.
            let flat = lines.map(expandingTabs)
            var result: [(MarkdownBlock, Int)] = []
            var i = 0
            while i < lines.count {
                let line = flat[i]
                let start = i
                let trimmed = line.trimmed
                if trimmed.isEmpty { i += 1; continue }
                if indent(line) >= 4 {
                    var code: [String] = []
                    while i < lines.count, indent(flat[i]) >= 4 || flat[i].trimmed.isEmpty {
                        code.append(dedent(lines[i], 4))
                        i += 1
                    }
                    while code.last?.trimmed.isEmpty == true { code.removeLast() }
                    result.append((.code(language: nil, text: code.joined(separator: "\n")), start))
                } else if let open = match(line, fence) {
                    var code: [String] = []
                    i += 1
                    while i < lines.count {
                        let close = flat[i].trimmed
                        if indent(flat[i]) < 4, close.hasPrefix(open[2]), close.allSatisfy({ $0 == open[2].first }) { i += 1; break }
                        code.append(dedent(lines[i], open[1].count))
                        i += 1
                    }
                    let language = open[3].split(separator: " ").first.map(String.init)
                    result.append((.code(language: language, text: code.joined(separator: "\n")), start))
                } else if trimmed.hasPrefix("$$"), let math = displayMath(flat, &i) {
                    result.append((.math(math), start))
                } else if let found = match(line, atx) {
                    var text = found[2]
                    if let closing = match(text, "^(.*?)(?:^|[ ]+)#+$") { text = closing[1] }
                    result.append((heading(found[1].count, text), start))
                    i += 1
                } else if match(line, rule) != nil {
                    result.append((.thematicBreak, start))
                    i += 1
                } else if match(line, quote) != nil {
                    var inner: [String] = []
                    while i < lines.count {
                        if match(flat[i], quote) != nil, let mark = lines[i].firstIndex(of: ">") {
                            inner.append(dedent(String(lines[i][lines[i].index(after: mark)...]), 1))
                        } else if !flat[i].trimmed.isEmpty, inner.last?.trimmed.isEmpty == false, !interrupts(flat[i]) {
                            inner.append(lines[i])
                        } else { break }
                        i += 1
                    }
                    if let head = match(expandingTabs(inner.first ?? ""), "^\\[!([A-Za-z-]+)\\]([-+]?)[ ]*(.*)$") {
                        let type = head[1].lowercased()
                        let title = head[3].isEmpty ? [.text(type.capitalized)] : inline(head[3])
                        let fold: MarkdownCalloutFold = head[2] == "-" ? .collapsed : head[2] == "+" ? .expanded : .fixed
                        let body = blocks(Array(inner.dropFirst()), depth: depth + 1).map(\.0)
                        result.append((.callout(type: type, title: title, fold: fold, blocks: body), start))
                    } else {
                        result.append((.blockquote(blocks(inner, depth: depth + 1).map(\.0)), start))
                    }
                } else if let found = match(line, footnote) {
                    var body = [found[2]]
                    i += 1
                    while i < lines.count {
                        if indent(flat[i]) >= 2 {
                            body.append(dedent(lines[i], 4))
                        } else if flat[i].trimmed.isEmpty, i + 1 < lines.count, indent(flat[i + 1]) >= 2 {
                            body.append("")
                        } else if !flat[i].trimmed.isEmpty, body.last?.isEmpty == false, !interrupts(flat[i]), match(flat[i], footnote) == nil {
                            body.append(lines[i])
                        } else { break }
                        i += 1
                    }
                    let parsed = blocks(body, depth: depth + 1).map(\.0)
                    footnotes[found[1]] = parsed
                } else if match(line, marker) != nil {
                    result.append((list(lines, flat, &i, depth: depth), start))
                } else if trimmed.contains("|"), i + 1 < lines.count, flat[i + 1].contains("-"),
                          match(flat[i + 1], delimiterRow) != nil, cells(line).count == cells(flat[i + 1]).count {
                    let alignments: [MarkdownColumnAlignment] = cells(flat[i + 1]).map {
                        switch ($0.hasPrefix(":"), $0.hasSuffix(":")) {
                        case (true, true): return .center
                        case (true, false): return .left
                        case (false, true): return .right
                        default: return .none
                        }
                    }
                    let header = cells(line).map { inline($0) }
                    var rows: [[[MarkdownInline]]] = []
                    i += 2
                    while i < lines.count, flat[i].contains("|"), !interrupts(flat[i]) {
                        var row = cells(flat[i]).prefix(header.count).map { inline($0) }
                        while row.count < header.count { row.append([]) }
                        rows.append(row)
                        i += 1
                    }
                    result.append((.table(alignments: alignments, header: header, rows: rows), start))
                } else {
                    var text = [line]
                    i += 1
                    var level = 0
                    while i < lines.count, !flat[i].trimmed.isEmpty {
                        if let setext = match(flat[i], "^ {0,3}(=+|-+)[ ]*$") {
                            level = setext[1].hasPrefix("=") ? 1 : 2
                            i += 1
                            break
                        }
                        if interrupts(flat[i]) { break }
                        text.append(flat[i])
                        i += 1
                    }
                    // Leading space goes; trailing double space stays because it marks a hard break.
                    var joined = text.map { String($0.drop { $0 == " " }) }.joined(separator: "\n")
                    while joined.last == " " { joined.removeLast() }
                    result.append((level > 0 ? heading(level, joined) : .paragraph(inline(joined)), start))
                }
            }
            return result
        }

        /// Link reference definitions apply to the whole document, so they are read first.
        private mutating func collectReferences(_ lines: inout [String]) {
            var openFence: String?
            for index in lines.indices {
                let line = expandingTabs(lines[index])
                if let open = openFence {
                    if line.trimmed.hasPrefix(open) { openFence = nil }
                } else if let found = match(line, MarkdownParser.fence) {
                    openFence = found[2]
                } else if let found = match(line, reference) {
                    references[found[1].lowercased()] = (found[2], found[3].isEmpty ? nil : found[3])
                    lines[index] = ""
                }
            }
        }

        private func displayMath(_ lines: [String], _ i: inout Int) -> String? {
            let first = String(lines[i].trimmed.dropFirst(2))
            if let close = first.range(of: "$$") {
                guard first[close.upperBound...].isEmpty else { return nil }
                i += 1
                return String(first[..<close.lowerBound]).trimmed
            }
            var body = [first]
            var j = i + 1
            while j < lines.count {
                let line = lines[j].trimmed
                if line.hasSuffix("$$") {
                    body.append(String(line.dropLast(2)))
                    i = j + 1
                    return body.joined(separator: "\n").trimmed
                }
                body.append(lines[j])
                j += 1
            }
            return nil
        }

        private mutating func list(_ lines: [String], _ flat: [String], _ i: inout Int, depth: Int) -> MarkdownBlock {
            let first = match(flat[i], marker)!
            let ordered = first[2].first!.isNumber
            let kind = first[2].last
            var items: [MarkdownListItem] = []
            var tight = true
            while i < lines.count, let found = match(flat[i], marker), found[2].last == kind, match(flat[i], rule) == nil {
                let width = found[1].count + found[2].count + (found[3].count > 4 || found[3].isEmpty ? 1 : found[3].count)
                var body = [found[3].count > 4 ? String(found[3].dropFirst()) + found[4] : found[4]]
                i += 1
                var blank = false
                while i < lines.count {
                    let line = flat[i]
                    if line.trimmed.isEmpty {
                        blank = true
                        body.append("")
                    } else if indent(line) >= width {
                        if blank, indent(line) == width, body.contains(where: { !$0.isEmpty }) { tight = false }
                        blank = false
                        body.append(dedent(lines[i], width))
                    } else if !blank, !interrupts(line), match(line, marker) == nil {
                        body.append(lines[i])
                    } else { break }
                    i += 1
                }
                if blank, i < lines.count, let next = match(flat[i], marker), next[2].last == kind { tight = false }
                var task: Bool?
                if let box = match(body[0], "^\\[([ xX])\\](?:[ ]+(.*))?$") {
                    task = box[1] != " "
                    body[0] = box[2]
                }
                items.append(MarkdownListItem(task: task, blocks: blocks(body, depth: depth + 1).map(\.0)))
            }
            return .list(ordered: ordered, start: ordered ? Int(first[2].dropLast()) ?? 1 : 1, tight: tight, items: items)
        }
    }

    // MARK: - Inline parser

    private struct InlineParser {
        let c: [Character]
        let references: [String: (String, String?)]
        var wikilinks: [MarkdownWikiLink] = []

        init(text: String, references: [String: (String, String?)]) {
            c = Array(text)
            self.references = references
        }

        mutating func parse() -> [MarkdownInline] { parse(0, c.count, depth: 0) }

        private func starts(_ token: String, _ at: Int, _ end: Int) -> Bool {
            var index = at
            for character in token {
                guard index < end, c[index] == character else { return false }
                index += 1
            }
            return true
        }

        private func find(_ token: String, _ from: Int, _ end: Int) -> Int? {
            var index = from
            while index < end {
                if starts(token, index, end) { return index }
                index += 1
            }
            return nil
        }

        private func run(_ at: Int, _ end: Int) -> Int {
            var index = at
            while index < end, c[index] == c[at] { index += 1 }
            return index - at
        }

        /// Index after the code span opening at `at`, or nil when it never closes.
        private func codeEnd(_ at: Int, _ end: Int) -> Int? {
            let length = run(at, end)
            var index = at + length
            while index < end {
                if c[index] == "`" {
                    let next = run(index, end)
                    if next == length { return index + next }
                    index += next
                } else { index += 1 }
            }
            return nil
        }

        private func closer(_ delimiter: Character, _ count: Int, _ from: Int, _ end: Int) -> Int? {
            var index = from
            while index < end {
                if c[index] == "\\" { index += 2; continue }
                if c[index] == "`", let after = codeEnd(index, end) { index = after; continue }
                if c[index] == delimiter {
                    let length = run(index, end)
                    let after = index + length
                    let flanking = index > from && !c[index - 1].isWhitespace
                    let intraword = delimiter == "_" && after < end && (c[after].isLetter || c[after].isNumber)
                    if flanking && !intraword && (length == count || (length >= 3 && count < length)) {
                        return after - count
                    }
                    index = after
                    continue
                }
                index += 1
            }
            return nil
        }

        private func bracketEnd(_ open: Int, _ end: Int, _ left: Character, _ right: Character) -> Int? {
            var depth = 0
            var index = open
            while index < end {
                if c[index] == "\\" { index += 2; continue }
                if c[index] == "`", let after = codeEnd(index, end) { index = after; continue }
                if c[index] == left { depth += 1 }
                if c[index] == right {
                    depth -= 1
                    if depth == 0 { return index }
                }
                index += 1
            }
            return nil
        }

        private mutating func parse(_ from: Int, _ end: Int, depth: Int) -> [MarkdownInline] {
            if depth > 16 { return [.text(String(c[from..<end]))] }
            var out: [MarkdownInline] = []
            var text = ""
            var i = from
            func emit(_ node: MarkdownInline) {
                if !text.isEmpty { out.append(.text(text)); text = "" }
                out.append(node)
            }
            while i < end {
                let ch = c[i]
                if ch == "\\", i + 1 < end {
                    if c[i + 1] == "\n" { emit(.lineBreak); i += 2; continue }
                    if c[i + 1].isASCII && (c[i + 1].isPunctuation || c[i + 1].isSymbol) { text.append(c[i + 1]); i += 2; continue }
                }
                if ch == "\n" {
                    let hard = text.hasSuffix("  ")
                    while text.hasSuffix(" ") { text.removeLast() }
                    emit(hard ? .lineBreak : .softBreak)
                    i += 1
                    continue
                }
                if ch == "`" {
                    let length = run(i, end)
                    if let after = codeEnd(i, end) {
                        var code = String(c[(i + length)..<(after - length)]).replacingOccurrences(of: "\n", with: " ")
                        if code.count > 1, code.hasPrefix(" "), code.hasSuffix(" "), !code.trimmed.isEmpty { code = String(code.dropFirst().dropLast()) }
                        emit(.code(code))
                        i = after
                    } else {
                        text += String(c[i..<(i + length)])
                        i += length
                    }
                    continue
                }
                if ch == "$" {
                    if starts("$$", i, end) {
                        if let close = find("$$", i + 2, end), close > i + 2 {
                            emit(.math(String(c[(i + 2)..<close]).trimmed, display: true))
                            i = close + 2
                        } else { text += "$$"; i += 2 }
                        continue
                    }
                    if i + 1 < end, !c[i + 1].isWhitespace {
                        var j = i + 1
                        while j < end, c[j] != "$" { j += c[j] == "\\" ? 2 : 1 }
                        if j < end, !c[j - 1].isWhitespace, !(j + 1 < end && c[j + 1].isNumber) {
                            emit(.math(String(c[(i + 1)..<j]), display: false))
                            i = j + 1
                            continue
                        }
                    }
                }
                let embed = starts("![[", i, end)
                if embed || starts("[[", i, end) {
                    let open = i + (embed ? 3 : 2)
                    if let close = find("]]", open, end) {
                        let body = String(c[open..<close])
                        if !body.isEmpty, !body.contains("["), !body.contains("\n") {
                            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                            let path = parts[0].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                            let link = MarkdownWikiLink(target: path[0].trimmed, heading: path.count > 1 ? path[1].trimmed : nil,
                                                        alias: parts.count > 1 ? parts[1].trimmed : nil, isEmbed: embed)
                            wikilinks.append(link)
                            emit(.wikilink(link))
                            i = close + 2
                            continue
                        }
                    }
                }
                if starts("[^", i, end), let close = find("]", i + 2, end), close > i + 2 {
                    let id = String(c[(i + 2)..<close])
                    if !id.contains(where: \.isWhitespace) { emit(.footnoteReference(id)); i = close + 1; continue }
                }
                let image = starts("![", i, end)
                if image || ch == "[" {
                    let open = image ? i + 1 : i
                    if let close = bracketEnd(open, end, "[", "]") {
                        var destination: (String, String?)?
                        var after = close + 1
                        if after < end, c[after] == "(", let paren = bracketEnd(after, end, "(", ")") {
                            var body = String(c[(after + 1)..<paren]).trimmed
                            var title: String?
                            if let found = match(body, "^(.*?)[ \\n]+[\"'](.*)[\"']$") { body = found[1]; title = found[2] }
                            if body.hasPrefix("<"), body.hasSuffix(">") { body = String(body.dropFirst().dropLast()) }
                            destination = (body, title)
                            after = paren + 1
                        } else {
                            var key = String(c[(open + 1)..<close])
                            if after < end, c[after] == "[", let second = find("]", after + 1, end) {
                                if second > after + 1 { key = String(c[(after + 1)..<second]) }
                                after = second + 1
                            }
                            destination = references[key.lowercased()]
                        }
                        if let destination {
                            let children = parse(open + 1, close, depth: depth + 1)
                            emit(image ? .image(alt: children.plainText, url: destination.0, title: destination.1)
                                       : .link(children, url: destination.0, title: destination.1))
                            i = after
                            continue
                        }
                    }
                }
                if ch == "<", let close = find(">", i + 1, end) {
                    let body = String(c[(i + 1)..<close])
                    if match(body, "^(https?://|mailto:)[^\\s<>]+$") != nil {
                        emit(.link([.text(body)], url: body, title: nil))
                        i = close + 1
                        continue
                    }
                }
                if ch == "*" || ch == "_" || ch == "~" {
                    let length = run(i, end)
                    let count = min(length, ch == "~" ? 2 : 3)
                    let after = i + length
                    let leftOK = after < end && !c[after].isWhitespace
                    let intraword = ch == "_" && i > from && (c[i - 1].isLetter || c[i - 1].isNumber)
                    if leftOK, !intraword, length <= 3, ch != "~" || count == 2, let close = closer(ch, count, after, end) {
                        let children = parse(after, close, depth: depth + 1)
                        if ch == "~" { emit(.strikethrough(children)) }
                        else if count == 3 { emit(.strong([.emphasis(children)])) }
                        else if count == 2 { emit(.strong(children)) }
                        else { emit(.emphasis(children)) }
                        i = close + count
                    } else {
                        text += String(c[i..<after])
                        i = after
                    }
                    continue
                }
                text.append(ch)
                i += 1
            }
            if !text.isEmpty { out.append(.text(text)) }
            return out
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
