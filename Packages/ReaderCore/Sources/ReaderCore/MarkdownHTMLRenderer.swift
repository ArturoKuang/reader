import Foundation

public struct MarkdownRenderOptions: Equatable, Sendable {
    public var documentDirectory: String
    public var vaultRoot: String?
    public var theme: String
    public var fontFamily: String
    public var fontScale: Double
    public var lineHeight: String
    public var marginPx: Int
    public var justify: Bool
    public var twoPages: Bool

    public init(documentDirectory: String, vaultRoot: String? = nil, theme: String = "original", fontFamily: String = "Original",
                fontScale: Double = 1, lineHeight: String = "1.6", marginPx: Int = 48, justify: Bool = false, twoPages: Bool = false) {
        self.documentDirectory = documentDirectory
        self.vaultRoot = vaultRoot
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontScale = fontScale
        self.lineHeight = lineHeight
        self.marginPx = marginPx
        self.justify = justify
        self.twoPages = twoPages
    }
}

public enum MarkdownHTMLRenderer {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The inner HTML of the article, used for the first load and for live reload.
    public static func renderArticleHTML(_ model: MarkdownDocumentModel, options: MarkdownRenderOptions, fs: FileSystem? = nil) -> String {
        var writer = Writer(model: model, options: options, fs: fs)
        var html = model.frontMatter.map(frontMatter) ?? ""
        for section in model.sections {
            html += "<section data-tts-section=\"\(section.index)\" data-anchor=\"\(escape(section.anchorID))\">\n\(writer.blocks(section.blocks))</section>\n"
        }
        return html + writer.footnotes()
    }

    public static func renderDocumentHTML(_ model: MarkdownDocumentModel, options: MarkdownRenderOptions, injectedScript: String, fs: FileSystem? = nil) -> String {
        let theme = ["original", "paper", "quiet", "night"].contains(options.theme) ? options.theme : "original"
        let sans = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif"
        let fonts = [
            "New York": "\"New York\", ui-serif, serif", "San Francisco": sans, "Georgia": "Georgia, serif",
            "Charter": "Charter, serif", "Iowan": "\"Iowan Old Style\", serif",
        ]
        let lineHeight = Double(options.lineHeight).map { String($0) } ?? "1.6"
        let variables = "--font-family: \(fonts[options.fontFamily] ?? sans); --font-scale: \(options.fontScale); --line-height: \(lineHeight); --page-margin: \(options.marginPx)px; --text-align: \(options.justify ? "justify" : "start");"
        let columns = options.twoPages ? "body { max-width: 1400px; } #reader-md-article { column-count: 2; column-gap: calc(var(--page-margin) * 1.5); }\n" : ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src reader-local: data:; font-src 'self' data:;">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(model.title))</title>
        <style>
        \(stylesheet)
        \(columns)</style>
        </head>
        <body data-theme="\(theme)" style="\(escape(variables))">
        <article id="reader-md-article">
        \(renderArticleHTML(model, options: options, fs: fs))</article>
        <script>\(injectedScript.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive))</script>
        </body>
        </html>
        """
    }

    private static func frontMatter(_ matter: MarkdownFrontMatter) -> String {
        guard !matter.fields.isEmpty else { return "" }
        let rows = matter.fields.map { field -> String in
            let values = field.items.isEmpty ? escape(field.value) : field.items.map { "<span class=\"md-fm-chip\">\(escape($0))</span>" }.joined()
            return "<div class=\"md-fm-key\">\(escape(field.key))</div><div class=\"md-fm-val\">\(values)</div>"
        }.joined()
        return "<details class=\"md-frontmatter\" data-tts-exclude=\"true\"><summary>Properties</summary><div class=\"md-fm-grid\">\(rows)</div></details>\n"
    }

    private static func encode(_ value: String, keeping extra: String = "") -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~" + extra)
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private struct Writer {
        let model: MarkdownDocumentModel
        let options: MarkdownRenderOptions
        let fs: FileSystem?
        /// Footnote ids in the order first referenced.
        var cited: [String] = []
        var citations: [String: Int] = [:]

        mutating func blocks(_ blocks: [MarkdownBlock], tight: Bool = false) -> String {
            var html = ""
            for block in blocks { html += self.block(block, tight: tight) + "\n" }
            return html
        }

        mutating func block(_ block: MarkdownBlock, tight: Bool) -> String {
            switch block {
            case .heading(let level, let id, let content):
                return "<h\(level) id=\"\(escape(id))\">\(inlines(content))</h\(level)>"
            case .paragraph(let content):
                return tight ? inlines(content) : "<p>\(inlines(content))</p>"
            case .blockquote(let children):
                return "<blockquote>\n\(blocks(children))</blockquote>"
            case .callout(let type, let title, let fold, let children):
                let head = inlines(title)
                let body = "<div class=\"callout-content\">\(blocks(children))</div>"
                let attributes = "class=\"callout\" data-callout=\"\(escape(type))\""
                if fold == .fixed { return "<div \(attributes)><div class=\"callout-title\">\(head)</div>\(body)</div>" }
                let open = fold == .expanded ? " open" : ""
                return "<details \(attributes)\(open)><summary class=\"callout-title\">\(head)</summary>\(body)</details>"
            case .list(let ordered, let start, let tight, let items):
                let name = ordered ? "ol" : "ul"
                var attributes = ordered && start != 1 ? " start=\"\(start)\"" : ""
                if items.contains(where: { $0.task != nil }) { attributes += " class=\"contains-task-list\"" }
                var html = "<\(name)\(attributes)>"
                for item in items {
                    let body = blocks(item.blocks, tight: tight)
                    if let task = item.task {
                        html += "<li class=\"task-list-item\(task ? " is-checked" : "")\"><input type=\"checkbox\" disabled\(task ? " checked" : "")><div>\(body)</div></li>"
                    } else {
                        html += "<li>\(body)</li>"
                    }
                }
                return html + "</\(name)>"
            case .table(let alignments, let header, let rows):
                var html = "<div class=\"md-table-wrap\"><table><thead>"
                html += row(header, "th", alignments) + "</thead><tbody>"
                for cells in rows { html += row(cells, "td", alignments) }
                return html + "</tbody></table></div>"
            case .code(let language, let text):
                let label = language.map { "<span class=\"md-code-lang\" data-tts-exclude=\"true\">\(escape($0))</span>" } ?? ""
                return "<pre>\(label)<code>\(SyntaxHighlighter.highlight(code: text, language: language))</code></pre>"
            case .math(let tex):
                return LaTeXMathRenderer.render(tex, display: true).mathML
            case .thematicBreak:
                return "<hr>"
            }
        }

        mutating func row(_ cells: [[MarkdownInline]], _ name: String, _ alignments: [MarkdownColumnAlignment]) -> String {
            var html = "<tr>"
            for (index, cell) in cells.enumerated() {
                var style = ""
                switch index < alignments.count ? alignments[index] : .none {
                case .left: style = " style=\"text-align: left\""
                case .center: style = " style=\"text-align: center\""
                case .right: style = " style=\"text-align: right\""
                case .none: break
                }
                html += "<\(name)\(style)>\(inlines(cell))</\(name)>"
            }
            return html + "</tr>"
        }

        mutating func inlines(_ nodes: [MarkdownInline]) -> String {
            var html = ""
            for node in nodes { html += inline(node) }
            return html
        }

        mutating func inline(_ node: MarkdownInline) -> String {
            switch node {
            case .text(let value): return escape(value)
            case .emphasis(let children): return "<em>\(inlines(children))</em>"
            case .strong(let children): return "<strong>\(inlines(children))</strong>"
            case .strikethrough(let children): return "<del>\(inlines(children))</del>"
            case .code(let value): return "<code>\(escape(value))</code>"
            case .link(let children, let url, let title):
                let body = inlines(children)
                guard isSafeLink(url) else { return body }
                let tip = title.map { " title=\"\(escape($0))\"" } ?? ""
                return "<a href=\"\(escape(url))\"\(tip)>\(body)</a>"
            case .image(let alt, let url, let title):
                return image(url, alt: alt, title: title, width: nil)
            case .wikilink(let link): return wikilink(link)
            case .math(let tex, let display): return LaTeXMathRenderer.render(tex, display: display).mathML
            case .footnoteReference(let id):
                guard model.footnotes[id] != nil else { return escape("[^\(id)]") }
                if !cited.contains(id) { cited.append(id) }
                let number = cited.firstIndex(of: id)! + 1
                citations[id, default: 0] += 1
                let suffix = citations[id]! > 1 ? "-\(citations[id]!)" : ""
                return "<a class=\"footnote-ref\" id=\"fnref-\(escape(id))\(suffix)\" href=\"#fn-\(escape(id))\" data-tts-exclude=\"true\">\(number)</a>"
            case .softBreak: return "\n"
            case .lineBreak: return "<br>\n"
            }
        }

        /// Only web, mail, Reader, fragment, and scheme-less links are clickable.
        func isSafeLink(_ url: String) -> Bool {
            let cleaned = url.filter { !$0.isWhitespace && !($0.asciiValue.map { $0 < 32 } ?? false) }.lowercased()
            guard let colon = cleaned.firstIndex(of: ":") else { return true }
            let scheme = cleaned[..<colon]
            if scheme.contains(where: { $0 == "/" || $0 == "#" || $0 == "?" }) { return true }
            return ["http", "https", "mailto", "reader", "obsidian"].contains(String(scheme))
        }

        /// Local files inside the document folder or vault are served by `reader-local://`.
        func localSource(_ url: String) -> String? {
            if url.lowercased().hasPrefix("data:image/") { return url }
            if url.contains(":") || url.hasPrefix("//") { return nil }
            let path = url.removingPercentEncoding ?? url
            let roots = [options.documentDirectory] + (options.vaultRoot.map { [$0] } ?? [])
            let absolute = Paths.normalize(path.hasPrefix("/") ? path : Paths.join(options.documentDirectory, path))
            guard roots.contains(where: { MarkdownWikiLinkResolver.isInside(absolute, $0) }) else { return nil }
            return "reader-local://file" + encode(absolute, keeping: "/")
        }

        func image(_ url: String, alt: String, title: String?, width: Int?) -> String {
            guard let source = localSource(url) else {
                // Remote images are never fetched; offer the link instead.
                let label = escape(alt.isEmpty ? url : alt)
                return isSafeLink(url) && url.contains(":") ? "<a class=\"md-remote-image\" href=\"\(escape(url))\">\(label)</a>" : label
            }
            var attributes = "src=\"\(escape(source))\" alt=\"\(escape(alt))\""
            if let title { attributes += " title=\"\(escape(title))\"" }
            if let width { attributes += " width=\"\(width)\"" }
            return "<img \(attributes)>"
        }

        func wikilink(_ link: MarkdownWikiLink) -> String {
            let resolution = fs.map {
                MarkdownWikiLinkResolver.resolve(target: link.target, heading: link.heading,
                                                 currentFilePath: Paths.join(options.documentDirectory, "document.md"),
                                                 vaultRoot: options.vaultRoot, fs: $0)
            }
            let lower = link.target.lowercased()
            if link.isEmbed, ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic"].contains(where: { lower.hasSuffix(".\($0)") }) {
                var path = Paths.join(options.documentDirectory, link.target)
                if case .file(let found, _) = resolution { path = found }
                let width = link.alias.flatMap { Int($0.prefix { $0.isNumber }) }
                return image(encode(path, keeping: "/"), alt: link.target, title: nil, width: width)
            }
            var href = "reader-wikilink://open?target=\(encode(link.target))"
            if let heading = link.heading { href += "&heading=\(encode(heading))" }
            var classes = link.isEmbed ? "md-wikilink md-embed" : "md-wikilink"
            if case .notFound = resolution { classes += " md-wikilink--unresolved" }
            return "<a class=\"\(classes)\" href=\"\(escape(href))\">\(escape(link.displayText))</a>"
        }

        mutating func footnotes() -> String {
            // Notes nobody cites still show, after the cited ones.
            var order = cited
            var items = ""
            var index = 0
            while true {
                if index == order.count {
                    let rest = model.footnotes.keys.filter { !order.contains($0) }.sorted()
                    if rest.isEmpty { break }
                    order += rest
                    cited = order
                }
                let id = order[index]
                let body = blocks(model.footnotes[id] ?? [])
                for added in cited where !order.contains(added) { order.append(added) }
                cited = order
                items += "<li id=\"fn-\(escape(id))\">\(body)<a class=\"footnote-backref\" href=\"#fnref-\(escape(id))\" data-tts-exclude=\"true\">↩</a></li>"
                index += 1
            }
            return items.isEmpty ? "" : "<section class=\"footnotes\" data-tts-exclude=\"true\"><ol>\(items)</ol></section>\n"
        }
    }
}
