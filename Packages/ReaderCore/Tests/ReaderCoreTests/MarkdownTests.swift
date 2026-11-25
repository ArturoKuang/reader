import XCTest
@testable import ReaderCore

final class MarkdownTests: XCTestCase {
    private func parse(_ source: String) -> MarkdownDocumentModel {
        MarkdownDocumentModel.parse(source: source, fileName: "/docs/Note.md")
    }

    private func html(_ source: String, fs: FileSystem? = nil, vault: String? = nil) -> String {
        MarkdownHTMLRenderer.renderArticleHTML(parse(source), options: MarkdownRenderOptions(documentDirectory: "/docs", vaultRoot: vault), fs: fs)
    }

    private func assertContains(_ text: String, _ parts: String..., file: StaticString = #filePath, line: UInt = #line) {
        for part in parts { XCTAssertTrue(text.contains(part), "missing \(part) in \(text)", file: file, line: line) }
    }

    func testFrontMatterIsParsedAndExcludedFromText() {
        let model = parse("---\ntitle: \"My Doc\"\ntags:\n  - alpha\n  - beta\nsecretkey: hidden\n---\nIntro\n\n# Head\nBody")
        XCTAssertEqual(model.title, "My Doc")
        XCTAssertEqual(model.frontMatter?.tags, ["alpha", "beta"])
        XCTAssertEqual(model.sections.map(\.anchorID), ["md-preamble", "head"])
        XCTAssertEqual(model.headings.first?.sourceLine, 10)
        XCTAssertEqual(model.headings.first?.sectionIndex, 1)
        XCTAssertFalse(model.bookText().pages.map(\.text).joined().contains("hidden"))
        assertContains(html("---\ntags: [a, b]\n---\nx"), "<details class=\"md-frontmatter\" data-tts-exclude=\"true\">", "md-fm-chip\">b<")
    }

    func testTitleFallbacksAndUniqueSlugs() {
        XCTAssertEqual(parse("plain").title, "Note")
        let model = parse("Overview\n===\n\n## Overview\n\n### **Overview** ###\n\nSub\n---\n")
        XCTAssertEqual(model.title, "Overview")
        XCTAssertEqual(model.headings.map(\.id), ["overview", "overview-1", "overview-2", "sub"])
        XCTAssertEqual(model.headings.map(\.level), [1, 2, 3, 2])
    }

    func testInlineFormatting() {
        let out = html("**b** *i* ***bi*** ~~s~~ `a<b` [l](https://x.test \"t\") snake_case_name  \nnext\n\n[ref][r] <https://y.test>\n\n[r]: /z.md")
        assertContains(out, "<strong>b</strong>", "<em>i</em>", "<strong><em>bi</em></strong>", "<del>s</del>", "<code>a&lt;b</code>",
                       "<a href=\"https://x.test\" title=\"t\">l</a>", "snake_case_name<br>", "<a href=\"/z.md\">ref</a>", "href=\"https://y.test\"")
    }

    func testListsTasksAndTables() {
        let out = html("- [x] done\n- [ ] todo\n  1. one\n     - deep\n\n| a | b | c |\n|:--|:-:|--:|\n| 1 | [[N\\|x]] | 3 |")
        assertContains(out, "contains-task-list", "disabled checked", "<ol>", "deep", "text-align: left", "text-align: center",
                       "text-align: right", ">x</a>")
        guard case .list(_, _, _, let items) = parse("- a\n  - b\n    - c").sections[0].blocks[0],
              case .list(_, _, _, let inner) = items[0].blocks[1] else { return XCTFail("not nested") }
        XCTAssertEqual(inner[0].blocks.count, 2)
    }

    func testCalloutsAndQuotes() {
        for type in ["note", "tip", "warning", "important", "caution", "info", "abstract", "summary", "todo", "success",
                     "question", "failure", "danger", "bug", "example", "quote"] {
            assertContains(html("> [!\(type)]\n> body"), "<div class=\"callout\" data-callout=\"\(type)\">", "body")
        }
        assertContains(html("> [!warning]- Careful\n> x"), "<details class=\"callout\" data-callout=\"warning\"><summary class=\"callout-title\">Careful</summary>")
        assertContains(html("> [!tip]+\n> x"), "data-callout=\"tip\" open>")
        assertContains(html("> said\nlazily"), "<blockquote>", "lazily")
    }

    func testCodeBlocksAndFootnotes() {
        let model = parse("```swift\nlet x = 1\n# not heading\n```\n\n    indented\n\nSee[^n].\n\n[^n]: The note.")
        XCTAssertTrue(model.headings.isEmpty)
        XCTAssertEqual(model.footnotes["n"]?.plainText, "The note.")
        let out = html("~~~py\ndef f(): pass\n~~~\n\nSee[^n].\n\n[^n]: The note.")
        assertContains(out, "tok-kw\">def", "href=\"#fn-n\"", "<li id=\"fn-n\">", "href=\"#fnref-n\"")
    }

    func testWikiLinkParsing() {
        let links = parse("[[Note]] [[Note|Alias]] [[Note#Sec]] [[Note#Sec|A]] ![[img.png|400]] `[[no]]`").wikilinks
        XCTAssertEqual(links.map(\.target), ["Note", "Note", "Note", "Note", "img.png"])
        XCTAssertEqual(links.map(\.heading), [nil, nil, "Sec", "Sec", nil])
        XCTAssertEqual(links.map(\.alias), [nil, "Alias", nil, "A", "400"])
        XCTAssertEqual(links.map(\.isEmbed), [false, false, false, false, true])
    }

    func testWikiLinkResolver() throws {
        let fs = MemoryFileSystem()
        for path in ["/vault/a/Sibling.md", "/vault/deep/er/Far.markdown", "/vault/assets/img.png", "/secret.md"] {
            try fs.createDirectory(Paths.parent(path))
            try fs.writeString(path, "x")
        }
        func resolve(_ target: String, _ heading: String? = nil) -> WikiLinkResolution {
            MarkdownWikiLinkResolver.resolve(target: target, heading: heading, currentFilePath: "/vault/a/Now.md", vaultRoot: "/vault", fs: fs)
        }
        XCTAssertEqual(resolve("", "My Part"), .localHeading(anchorID: "my-part"))
        XCTAssertEqual(resolve("Sibling", "A B"), .file(path: "/vault/a/Sibling.md", headingAnchor: "a-b"))
        XCTAssertEqual(resolve("far"), .file(path: "/vault/deep/er/Far.markdown", headingAnchor: nil))
        XCTAssertEqual(resolve("img.png"), .file(path: "/vault/assets/img.png", headingAnchor: nil))
        XCTAssertEqual(resolve("Missing"), .notFound(target: "Missing"))
        XCTAssertEqual(resolve("../../secret"), .notFound(target: "../../secret"))
        let out = html("[[Missing]] ![[img.png|400]]", fs: fs, vault: "/vault")
        assertContains(out, "md-wikilink--unresolved", "reader-wikilink://open?target=Missing",
                       "reader-local://file/vault/assets/img.png", "width=\"400\"")
    }

    func testMathDetection() {
        for source in ["Costs $5 and $10 today", "Pay \\$x\\$ now", "$100", "a $ b $ c", "`$x$`"] {
            XCTAssertFalse(html(source).contains("<math"), source)
        }
        assertContains(html("so $E = mc^2$."), "display=\"inline\"", "<msup><mi>c</mi><mn>2</mn></msup>")
        for source in ["$$x+1$$", "$$\nx+1\n$$"] {
            XCTAssertEqual(parse(source).sections[0].blocks, [.math("x+1")])
        }
    }

    func testMathML() {
        let out = LaTeXMathRenderer.render("\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}", display: true)
        assertContains(out.mathML, "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\">", "<munderover>", "<mfrac>", "<msqrt>", "<mi>π</mi>")
        assertContains(out.spokenText, "integral", "infinity", "square root of pi over 2")
        for name in ["pmatrix", "bmatrix", "cases"] {
            assertContains(LaTeXMathRenderer.render("\\begin{\(name)} a & b \\\\ c & d \\end{\(name)}", display: true).mathML, "<mtable><mtr><mtd><mi>a</mi></mtd>")
        }
        assertContains(LaTeXMathRenderer.render("\\left( \\hat{x} \\right) \\to \\text{a<b} \\mathbf{v}_i \\neq 1", display: false).mathML,
                       "<mover accent=\"true\">", "<mtext>a&lt;b</mtext>", "mathvariant=\"bold\"", "≠", "<mo>)</mo>")
    }

    func testMalformedMathTerminates() {
        for tex in ["}", "x^", "\\frac{", "\\left(", "\\right)", "\\begin{pmatrix} a &", "\\sqrt[", "\\", "a & b \\\\", "\\end{x}",
                    String(repeating: "{", count: 500)] {
            XCTAssertTrue(LaTeXMathRenderer.render(tex, display: false).mathML.hasSuffix("</math>"), tex)
        }
    }

    func testMalformedMarkdownTerminates() {
        for source in ["$$", "```", "---", "[[", "![](", "> [!", "**a", "|\n|-", String(repeating: ">", count: 200),
                       String(repeating: "[", count: 300), "<", "[^]:", "\\"] {
            _ = html(source)
        }
    }

    func testSyntaxHighlighting() {
        let samples = [("swift", "let a = \"<\" // c 1"), ("py", "def f(): return 1"), ("ts", "const a = 1"), ("js", "var a"),
                       ("rs", "fn main() {}"), ("go", "func main() {}"), ("zsh", "if true; then echo; fi"), ("sh", "export A=1"),
                       ("json", "{\"a\": true}"), ("yml", "a: true"), ("html", "<a href=\"x\">&</a>"), ("css", "a { color: red; }"),
                       ("sql", "SELECT * FROM t"), ("c", "int x;"), ("c++", "class A {};"), ("cpp", "return 0;"), ("md", "# Title")]
        for (language, code) in samples {
            let out = SyntaxHighlighter.highlight(code: code, language: language)
            XCTAssertTrue(out.contains("<span class=\"tok-"), language)
            let text = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            XCTAssertEqual(text, MarkdownHTMLRenderer.escape(code), language)
        }
        assertContains(SyntaxHighlighter.highlight(code: "let a = \"<\" // c", language: "swift"),
                       "tok-kw\">let", "tok-str\">&quot;&lt;&quot;", "tok-com\">// c")
        XCTAssertEqual(SyntaxHighlighter.highlight(code: "<x> & y", language: "brainfog"), "&lt;x&gt; &amp; y")
        for language in ["swift", "py", "html"] { _ = SyntaxHighlighter.highlight(code: "\"\\", language: language) }
    }

    func testDocumentIsOfflineAndEscaped() {
        let model = parse("<script>alert(1)</script>\n\n[x](javascript:alert(1)) ![r](https://evil.test/a.png) ![l](img/a%20b.png) ![o](../../etc/passwd)")
        for theme in ["original", "paper", "quiet", "night"] {
            var options = MarkdownRenderOptions(documentDirectory: "/docs", theme: theme)
            options.fontScale = 1.25
            options.justify = true
            options.twoPages = true
            let out = MarkdownHTMLRenderer.renderDocumentHTML(model, options: options, injectedScript: "")
            assertContains(out, "data-theme=\"\(theme)\"", "default-src 'none'", "--font-scale: 1.25", "--text-align: justify",
                           "column-count: 2", "body[data-theme=\"night\"]", "&lt;script&gt;", "reader-local://file/docs/img/a%20b.png")
            XCTAssertFalse(out.contains("<script>alert"))
            XCTAssertFalse(out.contains("href=\"javascript"))
            XCTAssertFalse(out.contains("src=\"http"))
            XCTAssertFalse(out.contains("<link"))
            XCTAssertFalse(out.contains("etc/passwd\""))
        }
    }

    func testBookKind() {
        for path in ["a.md", "a.MarkDown", "/x/a.MDOWN"] { XCTAssertEqual(BookKind.from(path: path), .markdown) }
        XCTAssertEqual(BookKind.from(path: "a.PDF"), .pdf)
        XCTAssertEqual(BookKind.from(path: "a.epub"), .epub)
        XCTAssertNil(BookKind.from(path: "a.txt"))
    }

    func testAISettingsBackwardCompatibility() throws {
        let old = try JSONDecoder().decode(AISettings.self, from: Data("{\"openAIModel\":\"m\"}".utf8))
        XCTAssertEqual(old.ttsRateMultiplier, 1.0)
        XCTAssertNil(old.ttsVoiceIdentifier)
        let new = AISettings(ttsRateMultiplier: 1.75, ttsVoiceIdentifier: "v")
        XCTAssertEqual(try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(new)), new)
    }

    func testAnchorsSortLinkAndReanchor() {
        let anchor = MarkdownAnchor.make(sectionIndex: 2, anchorID: "architecture", start: 14, end: 52)
        XCTAssertEqual(anchor.rawValue, "mdloc(s=2,a=architecture,o=14,e=52)")
        XCTAssertEqual(MarkdownAnchor(value: anchor.rawValue), anchor)
        XCTAssertNil(MarkdownAnchor(value: "epubcfi(/6/2)"))
        let link = ReaderLink(path: "/a.md", location: anchor.rawValue)
        XCTAssertEqual(ReaderLink.parse(link.url), link)
        XCTAssertNil(link.pageNumber)
        let highlights = [(2, 5), (0, 9), (2, 1)].enumerated().map { index, at in
            HighlightEntry(id: "h\(index)", color: 1, cfi: MarkdownAnchor.make(sectionIndex: at.0, anchorID: "a", start: at.1).rawValue, quote: "q\(index)")
        }
        XCTAssertEqual(AnnotationIndex.items(highlights: highlights, notes: []).map(\.id), ["h1", "h2", "h0"])
        let hit = Reanchorer.locate(quote: "target", prefix: "", suffix: "", in: parse("# A\n\n😀 target").textCorpus())
        XCTAssertEqual(hit?.cfi, "mdloc(s=0,a=a,o=5,e=11)")
    }
}
