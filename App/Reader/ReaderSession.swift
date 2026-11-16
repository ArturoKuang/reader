import AppKit
import ReaderCore

final class ReaderSession: ObservableObject {
    let bookURL: URL
    let bookData: Data
    let fingerprint: String
    var package: SidecarPackage
    var directory: String
    var placement: Placement
    var globalMarks: [MarkEntry]

    @Published var notice: String?
    @Published var offerMoveTo: String?
    @Published var needsReanchor: Bool
    @Published var toast: String?
    @Published var sidebar: SidebarMode
    @Published var panelVisible: Bool
    @Published var panelTab: PanelTab
    @Published var continuous: Bool
    @Published var twoPages: Bool
    @Published var fitMode: FitMode
    @Published var zoom: Double
    @Published var page: Int
    @Published var pageCount: Int
    @Published var sectionTitle: String
    @Published var outline: [OutlineRow]
    @Published var selection: SelectionContext?
    @Published var lookup: LookupPresentation?
    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var answerLabel: String = ""
    @Published var asking: Bool = false
    @Published var findQuery: String = ""
    @Published var findMatches: [String] = []
    @Published var expandedNotes: Set<String> = []
    @Published var provider: ProviderID
    @Published var settings: AISettings

    var pdfDocument: PDFDocument?
    var epub: EPUBBook?
    var epubRoot: URL?
    var bookText: BookText?
    var onDirty: (() -> Void)?
    var onPageChange: (() -> Void)?
    var navigation = NavigationHistory()
    private var markChord = MarkChord.idle
    private var lastLookupUndo: WordUndo?
    private var runner = ProcessCommandRunner()
    private var toastTimer: Timer?

    var isPDF: Bool { bookURL.pathExtension.lowercased() == "pdf" }
    var notes: [NoteEntry] { package.notes.notes }
    var words: [WordEntry] { package.words.words }
    var highlights: [HighlightEntry] { package.highlights.highlights }
    var marks: [MarkEntry] { package.marks.marks }
    var bookmarks: [Bookmark] { package.state.bookmarks }

    init(bookURL: URL, bookData: Data, open: OpenResult) {
        self.bookURL = bookURL
        self.bookData = bookData
        self.fingerprint = SHA256.fingerprint(bookData)
        self.package = open.package
        self.directory = open.directory
        self.placement = open.placement
        self.notice = open.notice
        self.offerMoveTo = open.offerMoveTo
        self.needsReanchor = open.needsReanchor
        let state = open.package.state
        self.sidebar = state.sidebar
        self.panelVisible = state.panelVisible
        self.panelTab = state.panelTab
        self.continuous = state.continuous
        self.twoPages = state.twoPages
        self.fitMode = state.fitMode
        self.zoom = state.zoom
        self.page = max(state.page, 1)
        self.pageCount = 1
        self.sectionTitle = ""
        self.outline = []
        self.settings = SettingsStore.load()
        self.provider = SettingsStore.load().defaultProvider
        self.globalMarks = GlobalMarks.load(applicationSupport: AppPaths.support, fs: LocalFileSystem())
        if isPDF {
            loadPDF()
        } else {
            loadEPUB()
        }
        prepareBookText()
    }

    func dismissNotice() {
        notice = nil
        offerMoveTo = nil
    }

    func acceptMove() {
        guard let destination = offerMoveTo else { return }
        let fs = LocalFileSystem()
        var index = LibraryIndex.load(from: AppPaths.indexFile, fs: fs)
        do {
            try SidecarStore.acceptMove(from: directory, to: destination, bookPath: bookURL.path, fingerprint: fingerprint, index: &index, fs: fs)
            try index.save(to: AppPaths.indexFile, fs: fs)
            directory = destination
            placement = .sibling
            offerMoveTo = nil
            notice = "Moved the notes next to this book."
        } catch {
            notice = error.localizedDescription
        }
    }

    func reanchor() {
        guard let bookText else { return }
        let report = Reanchorer.apply(package: &package, corpus: bookText.corpus())
        needsReanchor = false
        if report.unresolvedIDs.isEmpty {
            notice = "Re-anchored every note, highlight, word, and mark."
        } else {
            notice = "Couldn't place \(report.unresolvedIDs.count) \(report.unresolvedIDs.count == 1 ? "entry" : "entries"). They are listed as needing a new anchor."
        }
        dirty()
        objectWillChange.send()
    }

    func persistSidecar() throws {
        captureState()
        package.notes.frontMatter.fingerprint = fingerprint
        package.words.frontMatter = package.notes.frontMatter.withKind("words")
        package.highlights.frontMatter = package.notes.frontMatter.withKind("highlights")
        package.marks.frontMatter = package.notes.frontMatter.withKind("marks")
        let fs = LocalFileSystem()
        try package.write(to: directory, fs: fs)
        try GlobalMarks.save(globalMarks, applicationSupport: AppPaths.support, fs: fs)
    }

    func saveViewQuietly() {
        captureState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(package.state) {
            try? LocalFileSystem().write(Paths.join(directory, "state.json"), data)
        }
    }

    func setSidebar(_ mode: SidebarMode) {
        sidebar = mode
        package.state.sidebar = mode
        saveViewQuietly()
    }

    func setContinuous(_ value: Bool) {
        continuous = value
        package.state.continuous = value
        saveViewQuietly()
    }

    func setTwoPages(_ value: Bool) {
        twoPages = value
        package.state.twoPages = value
        saveViewQuietly()
    }

    func togglePanel() {
        panelVisible.toggle()
        package.state.panelVisible = panelVisible
        saveViewQuietly()
    }

    func show(tab: PanelTab) {
        panelVisible = true
        panelTab = tab
        package.state.panelVisible = true
        package.state.panelTab = tab
        saveViewQuietly()
    }

    func updatePage(_ page: Int, count: Int, section: String?) {
        self.page = page
        self.pageCount = count
        if let section, !section.isEmpty { sectionTitle = section }
        onPageChange?()
    }

    func rememberZoom(_ scale: Double, fit: FitMode) {
        zoom = scale
        fitMode = fit
        package.state.zoom = scale
        package.state.fitMode = fit
    }

    func highlight(color: Int) {
        guard HighlightPalette.isValid(color), let selection, !selection.text.isEmpty else { return }
        let entry = HighlightEntry(
            id: IDs.make("h"),
            color: color,
            page: selection.page,
            cfi: selection.cfi,
            quote: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            section: selection.section,
            rects: selection.rects
        )
        package.highlights.highlights.append(entry)
        package.state.lastHighlightColor = color
        showToast("Highlighted with color \(color)")
        dirty()
    }

    func highlightLast() {
        highlight(color: package.state.lastHighlightColor)
    }

    func addNote(body: String = "", ai: Bool = false, provider: String? = nil) {
        guard let selection, !selection.text.isEmpty else { return }
        let entry = NoteEntry(
            id: IDs.make("n"),
            page: selection.page,
            cfi: selection.cfi,
            quote: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            section: selection.section,
            created: ISO8601DateFormatter().string(from: Date()),
            ai: ai,
            provider: provider,
            scope: "passage",
            body: body
        )
        package.notes.notes.append(entry)
        expandedNotes.insert(entry.id)
        show(tab: .notes)
        dirty()
    }

    func updateNote(id: String, body: String) {
        guard let index = package.notes.notes.firstIndex(where: { $0.id == id }) else { return }
        package.notes.notes[index].body = body
        package.notes.notes[index].updated = ISO8601DateFormatter().string(from: Date())
        dirty()
    }

    func deleteNote(id: String) {
        package.notes.notes.removeAll { $0.id == id }
        expandedNotes.remove(id)
        dirty()
    }

    func toggleNote(_ id: String) {
        if expandedNotes.contains(id) { expandedNotes.remove(id) } else { expandedNotes.insert(id) }
    }

    func expandAllNotes() { expandedNotes = Set(package.notes.notes.map(\.id)) }
    func collapseAllNotes() { expandedNotes.removeAll() }

    func addBookmark() {
        let title = sectionTitle.isEmpty ? "Page \(page)" : sectionTitle
        let bookmark = Bookmark(id: IDs.make("b"), page: isPDF ? page : nil, cfi: isPDF ? nil : currentEPUBCFI(), title: title, section: sectionTitle)
        package.state.bookmarks.append(bookmark)
        if sidebar != .bookmarks { setSidebar(.bookmarks) }
        dirty()
    }

    func removeBookmark(id: String) {
        package.state.bookmarks.removeAll { $0.id == id }
        dirty()
    }

    func rotate(clockwise: Bool) {
        guard isPDF, let document = pdfDocument, let pdfPage = document.page(at: page - 1) else { return }
        let delta = clockwise ? 90 : -90
        let next = (pdfPage.rotation + delta + 360) % 360
        pdfPage.rotation = next
        package.state.rotations[String(page)] = next
        dirty()
    }

    func applyRotations() {
        guard let document = pdfDocument else { return }
        for (key, rotation) in package.state.rotations {
            guard let number = Int(key), let pdfPage = document.page(at: number - 1) else { continue }
            pdfPage.rotation = rotation
        }
    }

    func lookUp() {
        guard let selection else { return }
        let word = selection.text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).first.map(String.init) ?? selection.text
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let definition = ReaderDictionaryDefinition(term) ?? "No dictionary entry."
        let occurrence = LookupEntry(
            id: IDs.make("l"),
            page: selection.page,
            cfi: selection.cfi,
            section: selection.section,
            quote: term,
            prefix: selection.prefix,
            suffix: selection.suffix,
            sentence: selection.sentence.isEmpty ? selection.text : selection.sentence,
            date: ISO8601DateFormatter().string(from: Date())
        )
        let undo = WordStore.record(
            words: &package.words.words,
            word: term,
            definition: definition,
            explanation: nil,
            explanationProvider: nil,
            occurrence: occurrence,
            id: "w_\(WordStore.normalize(term))"
        )
        lastLookupUndo = undo
        dirty()
        let chosen = settings.lookupUsesDefault ? settings.defaultProvider : settings.lookupProvider
        lookup = LookupPresentation(
            word: WordStore.normalize(term),
            partOfSpeech: "",
            definition: definition,
            explanation: "",
            sentence: occurrence.sentence,
            location: locationLabel(selection),
            providerLabel: "Saved to words.md",
            undo: undo,
            busy: true
        )
        show(tab: .words)
        ask(purpose: .explainWord(term), provider: chosen, storeExplanationFor: term)
    }

    func undoLookup() {
        guard let undo = lookup?.undo ?? lastLookupUndo else { return }
        WordStore.undo(words: &package.words.words, undo)
        lookup = nil
        lastLookupUndo = nil
        dirty()
        showToast("Removed the lookup")
    }

    func setLearned(id: String, learned: Bool) {
        WordStore.setLearned(words: &package.words.words, id: id, learned: learned)
        dirty()
    }

    func ask(purpose: AIPurpose, provider override: ProviderID? = nil, storeExplanationFor word: String? = nil) {
        guard let bookText else {
            answer = "This book has no extracted text yet."
            return
        }
        let chosen = override ?? provider
        asking = true
        if panelTab != .askAI && word == nil { show(tab: .askAI) }
        let focus = selection.map { Focus(quote: $0.text, page: $0.page, section: $0.section, cfi: $0.cfi) }
        let directory = Paths.join(NSTemporaryDirectory(), "reader-ai-\(UUID().uuidString)")
        let router = AIRouter(
            settings: settings,
            openAIKey: KeychainStore.load(account: "openai"),
            anthropicKey: KeychainStore.load(account: "anthropic"),
            transport: URLSessionTransport(),
            runner: runner
        ) { [weak self] partial in
            Task { @MainActor in
                if word == nil { self?.answer = partial }
            }
        }
        Task { @MainActor in
            do {
                let result = try await router.answer(
                    book: bookText,
                    focus: focus,
                    purpose: purpose,
                    provider: chosen,
                    cliDirectory: directory,
                    originalBookPath: bookURL.path,
                    fs: LocalFileSystem()
                )
                if let word {
                    if let index = package.words.words.firstIndex(where: { WordStore.normalize($0.word) == WordStore.normalize(word) }) {
                        package.words.words[index].explanation = result.text
                        package.words.words[index].explanationProvider = chosen.label
                        dirty()
                    }
                    lookup?.explanation = result.text
                    lookup?.providerLabel = result.providerLabel
                    lookup?.busy = false
                } else {
                    answer = result.text
                    answerLabel = result.providerLabel
                }
            } catch {
                if word != nil {
                    lookup?.explanation = error.localizedDescription
                    lookup?.busy = false
                } else {
                    answer = error.localizedDescription
                    answerLabel = ""
                }
            }
            asking = false
        }
    }

    func askCurrentQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask(purpose: .ask(text))
    }

    func stopAsk() { runner.cancel() }

    func saveAnswerAsNote() {
        guard !answer.isEmpty else { return }
        if selection == nil {
            selection = SelectionContext(text: sectionTitle.isEmpty ? "Page note" : sectionTitle, page: page, cfi: currentEPUBCFI(), section: sectionTitle, prefix: "", suffix: "", sentence: "", rects: [])
        }
        addNote(body: answer, ai: true, provider: provider.rawValue)
    }

    func copyCitation() -> String? {
        guard let selection else { return nil }
        let where_ = locationLabel(selection)
        return "\(selection.text) — \(bookURL.deletingPathExtension().lastPathComponent), \(where_)"
    }

    func recordJump(from: ReadingPosition, to: ReadingPosition) {
        navigation.jump(from: from, to: to)
    }

    func backPosition(current: ReadingPosition) -> ReadingPosition? { navigation.back(current: current) }
    func forwardPosition(current: ReadingPosition) -> ReadingPosition? { navigation.forward(current: current) }

    func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.toast = nil }
        }
    }

    private func dirty() {
        captureState()
        onDirty?()
        objectWillChange.send()
    }

    private func captureState() {
        package.state.page = page
        package.state.zoom = zoom
        package.state.fitMode = fitMode
        package.state.continuous = continuous
        package.state.twoPages = twoPages
        package.state.sidebar = sidebar
        package.state.panelVisible = panelVisible
        package.state.panelTab = panelTab
    }

    private func locationLabel(_ selection: SelectionContext) -> String {
        if let page = selection.page { return "p. \(page)" }
        if let section = selection.section { return section }
        return sectionTitle
    }

    private func currentEPUBCFI() -> String? {
        guard let epub else { return nil }
        let index = min(max(page - 1, 0), max(epub.spine.count - 1, 0))
        return EPUBCFI.make(spineIndex: index, start: 0, end: 0).value
    }

    private func loadPDF() {
        pdfDocument = PDFDocument(data: bookData)
        pageCount = pdfDocument?.pageCount ?? 1
        outline = Self.outline(of: pdfDocument)
        applyRotations()
    }

    private func loadEPUB() {
        guard let book = try? EPUBBook(data: bookData) else {
            notice = "Couldn't read this EPUB."
            return
        }
        epub = book
        pageCount = max(book.spine.count, 1)
        outline = book.toc.enumerated().map { index, item in
            OutlineRow(id: "toc-\(index)", title: item.title, page: nil, cfi: item.href, depth: item.depth)
        }
        let root = URL(fileURLWithPath: Paths.join(AppPaths.caches, fingerprint.replacingOccurrences(of: ":", with: "-")))
        if let data = bookData as Data? {
            try? ZipArchive.extract(data, to: root.path, fs: LocalFileSystem())
            epubRoot = root
        }
        sectionTitle = book.spine.first?.title ?? book.title
    }

    private func prepareBookText() {
        if let cached = BookTextCache.load(caches: AppPaths.caches, fingerprint: fingerprint, fs: LocalFileSystem()) {
            bookText = cached
            return
        }
        let text: BookText
        if let pdfDocument {
            var pages: [BookPage] = []
            let sections = sectionByPage(outline: outline, count: pdfDocument.pageCount)
            for index in 0..<pdfDocument.pageCount {
                let string = pdfDocument.page(at: index)?.string ?? ""
                pages.append(BookPage(marker: "p. \(index + 1)", section: sections[index], text: string, page: index + 1))
            }
            text = BookText(title: bookURL.deletingPathExtension().lastPathComponent, pages: pages)
        } else if let epub {
            text = epub.bookText()
        } else {
            return
        }
        bookText = text
        try? BookTextCache.save(text, caches: AppPaths.caches, fingerprint: fingerprint, fs: LocalFileSystem())
    }

    private func sectionByPage(outline: [OutlineRow], count: Int) -> [String?] {
        var sections = [String?](repeating: nil, count: count)
        var current: String?
        var cursor = 0
        let sorted = outline.compactMap { row -> (Int, String)? in
            guard let page = row.page else { return nil }
            return (page, row.title)
        }.sorted { $0.0 < $1.0 }
        for (page, title) in sorted {
            let start = max(page - 1, 0)
            while cursor < start && cursor < count {
                sections[cursor] = current
                cursor += 1
            }
            current = title
        }
        while cursor < count {
            sections[cursor] = current
            cursor += 1
        }
        return sections
    }

    private static func outline(of document: PDFDocument?) -> [OutlineRow] {
        guard let root = document?.outlineRoot else { return [] }
        var rows: [OutlineRow] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let page = child.destination?.page.flatMap { document?.index(for: $0) }.map { $0 + 1 }
                rows.append(OutlineRow(id: "o-\(rows.count)", title: child.label ?? "Untitled", page: page, depth: depth))
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return rows
    }
}

// The mark store is mutated through a local copy. MarkController.handle takes inout MarkStore,
// so the session method below replaces the broken pair above.
extension ReaderSession {
    func handleMarkEvent(_ event: NSEvent, documentFocused: Bool, position: ReadingPosition) -> (consumed: Bool, jump: ReadingPosition?) {
        let character = event.characters
        let textInput = event.window?.firstResponder is NSTextView
        let key = MarkKey(
            character: character?.count == 1 ? character : nil,
            isEscape: event.keyCode == 53,
            hasCommandModifier: event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option),
            documentFocused: documentFocused,
            textInputFocused: textInput
        )
        var store = MarkStore(local: package.marks.marks, global: globalMarks)
        let result = MarkController.handle(
            chord: &markChord,
            key: key,
            store: &store,
            current: position,
            history: &navigation,
            bookFingerprint: fingerprint,
            bookPath: bookURL.path,
            title: bookURL.deletingPathExtension().lastPathComponent,
            now: ISO8601DateFormatter().string(from: Date()),
            makeID: { IDs.make("m") }
        )
        let changed = store.local != package.marks.marks || store.global != globalMarks
        package.marks.marks = store.local
        globalMarks = store.global
        if changed { dirty() }
        if let toast = result.toast { showToast(toast) }
        if let jump = result.jump, jump.openOtherBook, let path = jump.bookPath {
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, _ in }
            return (!result.passThrough && result.effect != .none, nil)
        }
        return (!result.passThrough && result.effect != .none, result.jump?.position)
    }
}
