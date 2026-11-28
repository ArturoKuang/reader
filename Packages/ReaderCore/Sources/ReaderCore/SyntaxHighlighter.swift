import Foundation

/// Table-driven tokenizer. Output is always HTML-escaped.
public enum SyntaxHighlighter {
    private struct Language {
        var keywords: Set<String>
        var comments: [String] = []
        var block: (String, String)?
        var quotes = "\"'"
        var ignoresCase = false
        var markup = false
        var markdown = false
        var keys = false
    }

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    private static let aliases = [
        "py": "python", "js": "javascript", "jsx": "javascript", "ts": "javascript", "tsx": "javascript", "typescript": "javascript",
        "rs": "rust", "golang": "go", "sh": "bash", "shell": "bash", "zsh": "bash", "yml": "yaml", "xml": "html", "svg": "html",
        "c++": "c", "cpp": "c", "cc": "c", "h": "c", "hpp": "c", "md": "markdown",
    ]

    private static let languages: [String: Language] = {
        let slash = ["//"]
        let c = ("/*", "*/")
        return [
            "swift": Language(keywords: words("actor as associatedtype async await break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil private protocol public repeat return self Self some any static struct subscript super switch throw throws true try typealias var where while"), comments: slash, block: c, quotes: "\""),
            "python": Language(keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self"), comments: ["#"]),
            "javascript": Language(keywords: words("abstract any as async await boolean break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface let new null number of private protected public readonly return set static string super switch this throw true try type typeof undefined var void while with yield"), comments: slash, block: c, quotes: "\"'`"),
            "rust": Language(keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"), comments: slash, block: c, quotes: "\""),
            "go": Language(keywords: words("break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var"), comments: slash, block: c, quotes: "\"'`"),
            "bash": Language(keywords: words("if then else elif fi for while until do done case esac function in return local export echo cd exit set unset source readonly shift"), comments: ["#"]),
            "json": Language(keywords: words("true false null"), quotes: "\"", keys: true),
            "yaml": Language(keywords: words("true false null yes no on off"), comments: ["#"], keys: true),
            "html": Language(keywords: [], block: ("<!--", "-->"), markup: true),
            "css": Language(keywords: words("important media import keyframes supports from to"), block: c, keys: true),
            "sql": Language(keywords: words("select from where insert into values update set delete create table drop alter add join left right inner outer full on group by order having limit offset as and or not null is in like between distinct union all primary key foreign references index view with case when then else end asc desc"), comments: ["--"], block: c, ignoresCase: true),
            "c": Language(keywords: words("alignas auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator private protected public register return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while NULL include define ifdef ifndef endif pragma"), comments: slash, block: c),
            "markdown": Language(keywords: [], markdown: true),
        ]
    }()

    public static func highlight(code: String, language: String?) -> String {
        let name = language?.lowercased() ?? ""
        guard let spec = languages[aliases[name] ?? name] else { return MarkdownHTMLRenderer.escape(code) }
        if spec.markdown { return markdown(code) }
        let c = Array(code)
        var out = ""
        var plain = ""
        var i = 0
        var inTag = false
        func emit(_ kind: String, _ end: Int) {
            out += MarkdownHTMLRenderer.escape(plain)
            plain = ""
            out += "<span class=\"tok-\(kind)\">\(MarkdownHTMLRenderer.escape(String(c[i..<end])))</span>"
            i = end
        }
        func starts(_ token: String, _ at: Int) -> Bool { c[at...].starts(with: token) }
        func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        func nextNonSpace(_ from: Int) -> Character? { c[from...].first { $0 != " " && $0 != "\t" } }
        while i < c.count {
            let ch = c[i]
            if let block = spec.block, starts(block.0, i) {
                var j = i + block.0.count
                while j < c.count, !starts(block.1, j) { j += 1 }
                emit("com", min(c.count, j + block.1.count))
            } else if spec.comments.contains(where: { starts($0, i) }),
                      !(spec.comments == ["#"] && i > 0 && !c[i - 1].isWhitespace) {
                var j = i
                while j < c.count, !c[j].isNewline { j += 1 }
                emit("com", j)
            } else if spec.markup {
                if ch == "<", i + 1 < c.count, c[i + 1].isLetter || c[i + 1] == "/" || c[i + 1] == "!" {
                    var j = i + 2
                    while j < c.count, isWord(c[j]) || c[j] == "-" || c[j] == ":" { j += 1 }
                    inTag = true
                    emit("kw", j)
                } else if inTag, ch == ">" {
                    inTag = false
                    emit("kw", i + 1)
                } else if inTag, ch == "\"" || ch == "'" {
                    var j = i + 1
                    while j < c.count, c[j] != ch { j += 1 }
                    emit("str", min(c.count, j + 1))
                } else if inTag, ch.isLetter {
                    var j = i + 1
                    while j < c.count, isWord(c[j]) || c[j] == "-" || c[j] == ":" { j += 1 }
                    emit("prop", j)
                } else { plain.append(ch); i += 1 }
            } else if spec.quotes.contains(ch) {
                let triple = String(repeating: ch, count: 3)
                var j: Int
                if starts(triple, i) {
                    j = i + 3
                    while j < c.count, !starts(triple, j) { j += 1 }
                    j += 3
                } else {
                    j = i + 1
                    while j < c.count, c[j] != ch, ch == "`" || !c[j].isNewline { j += c[j] == "\\" ? 2 : 1 }
                    j += 1
                }
                j = min(j, c.count)
                emit(spec.keys && nextNonSpace(j) == ":" ? "prop" : "str", j)
            } else if ch.isNumber {
                var j = i + 1
                while j < c.count, isWord(c[j]) || (c[j] == "." && j + 1 < c.count && c[j + 1].isNumber) { j += 1 }
                emit("num", j)
            } else if ch.isLetter || ch == "_" {
                var j = i + 1
                while j < c.count, isWord(c[j]) || (spec.keys && c[j] == "-") { j += 1 }
                let word = String(c[i..<j])
                if spec.keywords.contains(spec.ignoresCase ? word.lowercased() : word) { emit("kw", j) }
                else if spec.keys, nextNonSpace(j) == ":" { emit("prop", j) }
                else if j < c.count, c[j] == "(" { emit("fn", j) }
                else if ch.isUppercase { emit("type", j) }
                else { plain += word; i = j }
            } else if "+-*/%=<>!&|^~?".contains(ch) {
                emit("op", i + 1)
            } else {
                plain.append(ch)
                i += 1
            }
        }
        return out + MarkdownHTMLRenderer.escape(plain)
    }

    private static func markdown(_ code: String) -> String {
        code.components(separatedBy: "\n").map { line in
            let trimmed = line.drop { $0 == " " }
            let kind: String?
            if trimmed.hasPrefix("#") { kind = "kw" }
            else if trimmed.hasPrefix(">") { kind = "com" }
            else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { kind = "str" }
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { kind = "op" }
            else { kind = nil }
            let escaped = MarkdownHTMLRenderer.escape(line)
            return kind.map { "<span class=\"tok-\($0)\">\(escaped)</span>" } ?? escaped
        }.joined(separator: "\n")
    }
}
