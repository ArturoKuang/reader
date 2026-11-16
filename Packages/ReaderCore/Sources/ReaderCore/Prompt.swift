import Foundation

public struct BookPage: Equatable, Sendable, Codable {
    public var marker: String
    public var section: String?
    public var text: String
    public var page: Int?
    public var spineIndex: Int?

    public init(marker: String, section: String? = nil, text: String, page: Int? = nil, spineIndex: Int? = nil) {
        self.marker = marker
        self.section = section
        self.text = text
        self.page = page
        self.spineIndex = spineIndex
    }
}

public struct BookText: Equatable, Sendable, Codable {
    public var title: String
    public var pages: [BookPage]

    public init(title: String, pages: [BookPage]) {
        self.title = title
        self.pages = pages
    }

    public func corpus() -> TextCorpus {
        TextCorpus(slices: pages.map {
            TextSlice(page: $0.page, spineIndex: $0.spineIndex, section: $0.section, text: $0.text)
        })
    }
}

public struct Focus: Equatable, Sendable {
    public var quote: String
    public var page: Int?
    public var section: String?
    public var cfi: String?

    public init(quote: String, page: Int? = nil, section: String? = nil, cfi: String? = nil) {
        self.quote = quote
        self.page = page
        self.section = section
        self.cfi = cfi
    }
}

public enum AIPurpose: Equatable, Sendable {
    case ask(String)
    case explainWord(String)
    case explainSimply
    case summarizeSection
    case suggestNote
}

public enum ContextMode: String, Equatable, Sendable {
    case wholeBook
    case chapterPlusPassages
}

public struct PromptBundle: Equatable, Sendable {
    public var system: String
    public var user: String
    public var contextMode: ContextMode
    public var estimatedTokens: Int

    public init(system: String, user: String, contextMode: ContextMode, estimatedTokens: Int) {
        self.system = system
        self.user = user
        self.contextMode = contextMode
        self.estimatedTokens = estimatedTokens
    }
}

public enum PromptAssembly {
    public static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    /// `tokenBudget` is the maximum estimated size of the system prompt plus the user
    /// message. When the whole book does not fit, the current section is kept in full
    /// (truncated only if it alone exceeds the budget) and other paragraphs are added
    /// by overlap with the question and the focus.
    public static func assemble(book: BookText, focus: Focus?, purpose: AIPurpose, tokenBudget: Int) -> PromptBundle {
        let system = systemPrompt(partial: false)
        let question = questionLine(purpose)
        let fullUser = renderBook(book, pages: book.pages, partial: false)
            + "\n" + renderFocus(focus)
            + "\n" + question
        if estimateTokens(system + fullUser) <= max(tokenBudget, 1) {
            return PromptBundle(system: system, user: fullUser, contextMode: .wholeBook, estimatedTokens: estimateTokens(system + fullUser))
        }

        let partialSystem = systemPrompt(partial: true)
        let focusPages = relevantPages(book: book, focus: focus)
        var chosen: [BookPage] = []
        var used = estimateTokens(partialSystem + renderFocus(focus) + question + "<book title=\"\" pages=\"0\" partial=\"chapter-plus-passages\">\n</book>\n")
        for page in focusPages {
            let piece = renderPage(page)
            let cost = estimateTokens(piece)
            if used + cost > tokenBudget && !chosen.isEmpty {
                break
            }
            if used + cost > tokenBudget {
                var truncated = page
                truncated.text = truncate(page.text, budget: max(32, tokenBudget - used))
                chosen.append(truncated)
                used += estimateTokens(renderPage(truncated))
                break
            }
            chosen.append(page)
            used += cost
        }

        let terms = tokens(of: (focus?.quote ?? "") + " " + questionText(purpose))
        var passages: [(page: BookPage, text: String, score: Int)] = []
        for page in book.pages where !focusPages.contains(where: { $0.marker == page.marker && $0.page == page.page && $0.spineIndex == page.spineIndex }) {
            for paragraph in page.text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                let score = tokens(of: paragraph).intersection(terms).count
                if score > 0 {
                    passages.append((page, paragraph, score))
                }
            }
        }
        passages.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.page.page ?? lhs.page.spineIndex ?? 0) < (rhs.page.page ?? rhs.page.spineIndex ?? 0)
        }
        var extras: [BookPage] = []
        for passage in passages {
            let page = BookPage(marker: passage.page.marker, section: passage.page.section, text: passage.text, page: passage.page.page, spineIndex: passage.page.spineIndex)
            let cost = estimateTokens(renderPage(page))
            if used + cost > tokenBudget { continue }
            extras.append(page)
            used += cost
        }
        let pages = chosen + extras
        let user = renderBook(book, pages: pages, partial: true) + "\n" + renderFocus(focus) + "\n" + question
        return PromptBundle(system: partialSystem, user: user, contextMode: .chapterPlusPassages, estimatedTokens: estimateTokens(partialSystem + user))
    }

    public static func bookFile(_ book: BookText) -> String {
        book.pages.map { "[\($0.marker)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    public static func focusFile(book: BookText, focus: Focus?, question: String) -> String {
        var lines = ["# Focus", ""]
        lines.append("Book: \(book.title)")
        if let page = focus?.page { lines.append("Page: \(page)") }
        if let section = focus?.section { lines.append("Section: \(section)") }
        if let cfi = focus?.cfi { lines.append("CFI: \(cfi)") }
        lines.append("")
        lines.append("Selection:")
        lines.append("> \(focus?.quote ?? "")")
        lines.append("")
        lines.append("Question:")
        lines.append(question)
        lines.append("")
        lines.append("Cite pages as (p. N). Do not modify any files.")
        return lines.joined(separator: "\n")
    }

    private static func systemPrompt(partial: Bool) -> String {
        var text = "You answer questions about the book below. Cite pages as (p. N)."
        if partial {
            text += " The book was longer than the context window, so this request has the current section and the passages that best match the question. Say if the answer needs text you were not given."
        }
        return text
    }

    private static func questionLine(_ purpose: AIPurpose) -> String {
        "Question: " + questionText(purpose)
    }

    private static func questionText(_ purpose: AIPurpose) -> String {
        switch purpose {
        case .ask(let question):
            return question
        case .explainWord(let word):
            return "In this passage, what does \"\(word)\" mean?"
        case .explainSimply:
            return "Explain this passage in simpler words."
        case .summarizeSection:
            return "Summarize this section."
        case .suggestNote:
            return "Suggest a short reading note for this passage, written the way the reader might keep it."
        }
    }

    private static func relevantPages(book: BookText, focus: Focus?) -> [BookPage] {
        if let section = focus?.section, !section.isEmpty {
            let matches = book.pages.filter { $0.section == section }
            if !matches.isEmpty { return matches }
        }
        if let page = focus?.page, let match = book.pages.first(where: { $0.page == page }) {
            return [match]
        }
        if let focus, let match = book.pages.first(where: { $0.text.contains(focus.quote) }) {
            return [match]
        }
        return Array(book.pages.prefix(1))
    }

    private static func renderBook(_ book: BookText, pages: [BookPage], partial: Bool) -> String {
        let partialAttribute = partial ? " partial=\"chapter-plus-passages\"" : ""
        var text = "<book title=\"\(escape(book.title))\" pages=\"\(book.pages.count)\"\(partialAttribute)>\n"
        for page in pages {
            text += renderPage(page)
        }
        text += "</book>"
        return text
    }

    private static func renderPage(_ page: BookPage) -> String {
        var text = "[\(page.marker)]\n"
        text += page.text
        if !page.text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private static func renderFocus(_ focus: Focus?) -> String {
        guard let focus else { return "<focus>\n\n</focus>" }
        var attributes = ""
        if let page = focus.page { attributes += " page=\"\(page)\"" }
        if let section = focus.section, !section.isEmpty { attributes += " section=\"\(escape(section))\"" }
        if let cfi = focus.cfi, !cfi.isEmpty { attributes += " cfi=\"\(escape(cfi))\"" }
        return "<focus\(attributes)>\n\(focus.quote)\n</focus>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func tokens(of text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    private static func truncate(_ text: String, budget: Int) -> String {
        let limit = max(16, budget * 4)
        if text.utf8.count <= limit { return text }
        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[..<end]) + "…"
    }
}

public enum BookTextCache {
    public static func path(caches: String, fingerprint: String) -> String {
        let name = fingerprint.replacingOccurrences(of: ":", with: "-") + ".json"
        return Paths.join(Paths.join(caches, "Reader"), name)
    }

    public static func load(caches: String, fingerprint: String, fs: FileSystem) -> BookText? {
        let file = path(caches: caches, fingerprint: fingerprint)
        guard fs.exists(file), let data = try? fs.read(file) else { return nil }
        return try? JSONDecoder().decode(BookText.self, from: data)
    }

    public static func save(_ book: BookText, caches: String, fingerprint: String, fs: FileSystem) throws {
        let file = path(caches: caches, fingerprint: fingerprint)
        try fs.createDirectory(Paths.parent(file))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.write(file, try encoder.encode(book))
    }
}
