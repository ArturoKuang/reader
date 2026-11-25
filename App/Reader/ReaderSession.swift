import AppKit
import PDFKit
import ReaderCore
import UniformTypeIdentifiers

final class ReaderSession: ObservableObject {
    let bookURL: URL
    let bookKind: BookKind
    private(set) var bookData: Data
    private(set) var fingerprint: String
    var package: SidecarPackage
    var directory: String
    var placement: Placement
    var globalMarks: [MarkEntry]

    @Published var notice: String?
    @Published var offerMoveTo: String?
    @Published var needsReanchor: Bool
    @Published var toast: String?
    @Published var concepts: [Concept] = []
    @Published var mastery: [String: MasteryRecord] = [:]
    @Published var tutorLines: [String] = []
    @Published var showConceptMarkers = true
    var usesVault = false
    var vaultName: String?
    var vaultRoot: String?
    var bookFolder: String?
    var tutorAvailable = false
    var claudeSessionID: String?
    var onVaultFlush: (() -> Void)?
    /// AppKit/WebKit refresh the current passage, then run the action. PDF is synchronous.
    var onCaptureSelection: ((@escaping () -> Void) -> Void)?
    var onSaveVaultState: (() -> Void)?
    /// Starts Read Aloud at `selection`.
    var onReadFromSelection: (() -> Void)?
    var onInsertConcept: ((Concept) -> Void)?
    @Published var vaultNotesFolder = "notes"
    @Published var vaultVocabularyFile = ""
    @Published var vaultEnabled = true
    var vaultLoose = false
    @Published var askChoice = ""
    @Published var focusQuestion = 0
    @Published var aiSetup: String?
    @Published var noteDraft = ""
    var pendingReaderLink: ReaderLink?
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
    @Published var chat: [ReaderChatLine] = []
    private var chatQuote = ""
    @Published var answerLabel: String = ""
    @Published var asking: Bool = false
    @Published var findQuery: String = ""
    @Published var searchHits: [SearchHit] = []
    @Published var searchIndex = 0
    var sidebarBeforeSearch: SidebarMode?
    @Published var findMatches: [String] = []
    @Published var expandedNotes: Set<String> = []
    @Published var annotationQuery = ""
    @Published var annotationFilter = "all"
    @Published var annotationSortRecent = false
    @Published var annotationSelection = Set<String>()
    private var deletingAnnotations = false
    @Published var annotationRevision = 0
    @Published var showMarginNotes = false
    var onPresentNote: ((String) -> Void)?
    var onRevealInObsidian: ((String?) -> Void)?
    var onRelocateNotes: ((String, String, Bool) -> Void)?
    private var noteSaveTimer: Timer?
    private var pendingNoteBodies: [String: String] = [:]
    private var noteEditBaseline: [String: String] = [:]
    var chatAnchor: SelectionContext?
    @Published var provider: ProviderID
    @Published var settings: AISettings

    var pdfDocument: PDFDocument?
    var epub: EPUBBook?
    @Published private(set) var markdown: MarkdownDocumentModel?
    /// A heading to scroll to once the document is on screen.
    var pendingAnchor: String?
    var epubRoot: URL?
    var bookText: BookText?
    var onDirty: (() -> Void)?
    var onPageChange: (() -> Void)?
    var onAnnotationsChanged: (() -> Void)?
    var onToast: ((String?) -> Void)?
    weak var undoManager: UndoManager?
    /// True when `state.json` already existed. A first open fits the page width.
    let hasSavedViewState: Bool
    /// Stays true until the saved page and window frame have been applied, so layout cannot overwrite them.
    var viewRestorePending: Bool
    var navigation = NavigationHistory()
    private var markChord = MarkChord.idle
    private var lastLookupUndo: WordUndo?
    private var runner = ProcessCommandRunner()
    private var toastTimer: Timer?
    private var viewStateTimer: Timer?

    var isPDF: Bool { bookKind == .pdf }
    var isEPUB: Bool { bookKind == .epub }
    var isMarkdown: Bool { bookKind == .markdown }
    var isWebDocument: Bool { !isPDF }
    var notes: [NoteEntry] { package.notes.notes }
    var words: [WordEntry] { package.words.words }
    var highlights: [HighlightEntry] { package.highlights.highlights }
    var marks: [MarkEntry] { package.marks.marks }
    var bookmarks: [Bookmark] { package.state.bookmarks }

    init(bookURL: URL, bookData: Data, open: OpenResult) {
        self.bookURL = bookURL
        self.bookKind = BookKind.from(path: bookURL.path) ?? .pdf
        self.bookData = bookData
        self.fingerprint = SHA256.fingerprint(bookData)
        self.package = open.package
        self.directory = open.directory
        self.placement = open.placement
        self.notice = open.notice
        self.offerMoveTo = open.offerMoveTo
        self.needsReanchor = open.needsReanchor
        self.hasSavedViewState = open.hasSavedViewState
        self.viewRestorePending = open.hasSavedViewState
        let state = open.package.state
        self.sidebar = state.sidebar
        self.panelVisible = state.panelVisible
        self.panelTab = state.panelTab
        self.continuous = state.continuous
        self.twoPages = state.twoPages
        self.fitMode = state.fitMode
        self.zoom = state.zoom
        self.page = max(state.page, 1)
        self.showMarginNotes = state.showMarginNotes
        self.pageCount = 1
        self.sectionTitle = ""
        self.outline = []
        self.settings = SettingsStore.load()
        self.provider = SettingsStore.load().defaultProvider
        self.globalMarks = GlobalMarks.load(applicationSupport: AppPaths.support, fs: LocalFileSystem())
        switch bookKind {
        case .pdf: loadPDF()
        case .epub: loadEPUB()
        case .markdown: loadMarkdown()
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

    func finishViewRestore() {
        guard viewRestorePending else { return }
        DispatchQueue.main.async { [weak self] in
            self?.viewRestorePending = false
        }
    }

    func saveViewQuietly() {
        guard !viewRestorePending else { return }
        captureState()
        if usesVault {
            onSaveVaultState?()
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(package.state) {
            try? LocalFileSystem().write(Paths.join(directory, "state.json"), data)
        }
    }

    /// Writes view state shortly after zoom, scroll, page, or frame changes.
    func scheduleViewStateSave() {
        let arm = {
            self.viewStateTimer?.invalidate()
            let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.saveViewQuietly()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.viewStateTimer = timer
        }
        if Thread.isMainThread {
            arm()
        } else {
            DispatchQueue.main.async(execute: arm)
        }
    }

    func saveViewNow() {
        viewStateTimer?.invalidate()
        viewStateTimer = nil
        saveViewQuietly()
    }

    func noteWindowFrame(x: Double, y: Double, width: Double, height: Double) {
        guard !viewRestorePending else { return }
        guard width > 320, height > 240 else { return }
        package.state.windowFrame = StoredWindowFrame(x: x, y: y, width: width, height: height)
        scheduleViewStateSave()
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
        let opens = UserDefaults.standard.object(forKey: "reader.openInspector") as? Bool ?? true
        guard panelVisible || opens else { return }
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
        guard scale.isFinite, scale > 0.05 else { return }
        zoom = scale
        fitMode = fit
        package.state.zoom = scale
        package.state.fitMode = fit
        scheduleViewStateSave()
    }

    func highlight(color: Int) {
        guard HighlightPalette.isValid(color), let selection, !selection.text.isEmpty else { return }
        let anchor = AnnotationAnchor(text: selection.text, page: selection.page, cfi: selection.cfi, section: selection.section, prefix: selection.prefix, suffix: selection.suffix, rects: selection.rects)
        if let existing = AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, in: highlights) {
            recolorAnnotation(id: existing.id, color: color)
            showToast("Highlighted with \(HighlightCallout.name(for: color))")
            return
        }
        editAnnotations("Highlight") {
            _ = AnnotationEdit.addHighlight(selection: anchor, color: color, id: IDs.make("h"), package: &package)
        }
        showToast("Highlighted with \(HighlightCallout.name(for: color))")
    }

    func deleteHighlight(id: String) {
        removeAnnotationCompletely(id: id)
    }

    func restoreHighlight(_ entry: HighlightEntry) {
        package.highlights.highlights.append(entry)
        undoManager?.registerUndo(withTarget: self) { session in
            session.deleteHighlight(id: entry.id)
        }
        undoManager?.setActionName("Remove Highlight")
        onAnnotationsChanged?()
        dirty()
    }

    func rememberScroll(_ position: ReadingPosition) {
        package.state.scrollY = position.scrollY
        if let page = position.page {
            package.state.page = page
            self.page = page
        }
        scheduleViewStateSave()
    }

    func highlightLast() {
        highlight(color: package.state.lastHighlightColor)
    }

    func commitNoteDraft() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let before = package.notes.notes.count
        addNote(body: text)
        if package.notes.notes.count != before { noteDraft = "" }
    }

    func addNote(body: String = "", ai: Bool = false, provider: String? = nil) {
        guard let selection, !selection.text.isEmpty else { return }
        let typed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.isEmpty ? typed : body
        let anchor = AnnotationAnchor(text: selection.text, page: selection.page, cfi: selection.cfi, section: selection.section ?? sectionTitle, prefix: selection.prefix, suffix: selection.suffix, rects: selection.rects)
        var opened: String?
        editAnnotations("Add Note") {
            let created = AnnotationEdit.addNote(toSelection: anchor, color: package.state.lastHighlightColor, highlightID: IDs.make("h"), noteID: IDs.make("n"), now: ISO8601DateFormatter().string(from: Date()), package: &package)
            if let noteID = created.note?.id, !text.isEmpty {
                AnnotationEdit.updateNoteBody(id: noteID, body: text, now: ISO8601DateFormatter().string(from: Date()), package: &package)
                if let index = package.notes.notes.firstIndex(where: { $0.id == noteID }) {
                    package.notes.notes[index].ai = ai
                    package.notes.notes[index].provider = provider
                }
            }
            opened = created.highlight?.id ?? created.note?.id
        }
        noteDraft = ""
        show(tab: .notes)
        if let opened {
            lastAnnotationHit = opened
            onPresentNote?(opened)
        }
    }

    func addNote(to selection: SelectionContext, body: String, ai: Bool, provider: String?) {
        let anchor = AnnotationAnchor(text: selection.text, page: selection.page, cfi: selection.cfi, section: selection.section ?? sectionTitle, prefix: selection.prefix, suffix: selection.suffix, rects: selection.rects)
        editAnnotations("Add Note") {
            let created = AnnotationEdit.addNote(toSelection: anchor, color: package.state.lastHighlightColor, highlightID: IDs.make("h"), noteID: IDs.make("n"), now: ISO8601DateFormatter().string(from: Date()), package: &package)
            if let noteID = created.note?.id {
                AnnotationEdit.updateNoteBody(id: noteID, body: body, now: ISO8601DateFormatter().string(from: Date()), package: &package)
                if let index = package.notes.notes.firstIndex(where: { $0.id == noteID }) {
                    package.notes.notes[index].ai = ai
                    package.notes.notes[index].provider = provider
                }
            }
        }
    }

    func updateNote(id: String, body: String) {
        queueNoteBody(id: id, body: body)
    }

    func deleteNote(id: String) {
        removeNoteOnly(id: id)
    }

    var lastAnnotationHit: String?

    func toggleNote(_ id: String) {
        if expandedNotes.contains(id) { expandedNotes.remove(id) } else { expandedNotes.insert(id) }
    }

    func expandAllNotes() { expandedNotes = Set(package.notes.notes.map(\.id)) }
    func collapseAllNotes() { expandedNotes.removeAll() }

    func addBookmark() { toggleBookmark() }

    func toggleBookmark() {
        let title = sectionTitle.isEmpty ? "Page \(page)" : sectionTitle
        let pageNumber = isPDF ? page : nil
        let cfi = isPDF ? nil : currentLocation()
        let before = package.state.bookmarks
        let added = BookmarkEdit.toggle(page: pageNumber, cfi: cfi, title: title, section: sectionTitle, id: IDs.make("b"), bookmarks: &package.state.bookmarks)
        undoManager?.registerUndo(withTarget: self) { session in
            session.package.state.bookmarks = before
            session.dirty()
        }
        undoManager?.setActionName(added == nil ? "Remove Bookmark" : "Add Bookmark")
        dirty()
    }

    func bookmarkExistsForCurrentPosition() -> Bool {
        let pageNumber = isPDF ? page : nil
        let cfi = isPDF ? nil : currentLocation()
        return package.state.bookmarks.contains { BookmarkEdit.matches($0, page: pageNumber, cfi: cfi) }
    }

    func renameBookmark(id: String, title: String) {
        guard let index = package.state.bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let previous = package.state.bookmarks[index].title
        package.state.bookmarks[index].title = title
        undoManager?.registerUndo(withTarget: self) { session in
            session.renameBookmark(id: id, title: previous)
        }
        undoManager?.setActionName("Rename Bookmark")
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
        let rawDefinition = ReaderDictionaryDefinition(term) ?? ""
        let definition = rawDefinition.isEmpty || rawDefinition.hasPrefix("Error") || rawDefinition.contains("ReaderFailure")
            ? "No dictionary entry."
            : VocabularyFile.shortMeaning(rawDefinition)
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
            providerLabel: usesVault ? "Saved to the vocabulary file" : "Saved to words.md",
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

    func deleteWord(id: String) {
        package.words.words.removeAll { $0.id == id }
        dirty()
    }

    func setLearned(id: String, learned: Bool) {
        WordStore.setLearned(words: &package.words.words, id: id, learned: learned)
        dirty()
    }

    func ask(purpose: AIPurpose, provider override: ProviderID? = nil, storeExplanationFor word: String? = nil) {
        guard let bookText else {
            let message = "This book has no extracted text yet."
            answer = message
            chat.append(ReaderChatLine(id: UUID(), mine: false, text: message))
            return
        }
        let chosen = override ?? provider
        asking = true
        if word == nil {
            let quote = selection?.text ?? ""
            if quote != chatQuote {
                chatQuote = quote
                chatAnchor = selection
                chat = []
            }
            chat.append(ReaderChatLine(id: UUID(), mine: true, text: chatLabel(purpose)))
            chat.append(ReaderChatLine(id: UUID(), mine: false, text: ""))
            show(tab: .askAI)
        }
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
                if word == nil {
                    self?.answer = partial
                    if let last = self?.chat.indices.last { self?.chat[last].text = partial }
                }
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
                    if let last = chat.indices.last { chat[last].text = result.text }
                }
            } catch {
                let message = (error as? AIError)?.userMessage ?? (error as? ReaderFailure)?.message ?? error.localizedDescription
                if message.contains("Settings") { aiSetup = message }
                if word != nil {
                    lookup?.explanation = message
                    lookup?.busy = false
                } else {
                    answer = message
                    answerLabel = ""
                    if let last = chat.indices.last { chat[last].text = message }
                }
            }
            asking = false
        }
    }

    private func chatLabel(_ purpose: AIPurpose) -> String {
        switch purpose {
        case .ask(let text): return text
        case .explainWord(let word): return "Define \(word)"
        case .explainSimply: return "Explain"
        case .summarizeSection: return "Summarize"
        case .suggestNote: return "Suggest a note"
        }
    }

    func withSelection(_ body: @escaping () -> Void) {
        guard let onCaptureSelection else {
            body()
            return
        }
        onCaptureSelection(body)
    }

    func askCurrentQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if askChoice == "tutor", usesVault, tutorAvailable {
            askTutor(command: nil, question: text)
        } else {
            let chosen = ProviderID(rawValue: askChoice) ?? provider
            ask(purpose: .ask(text), provider: chosen)
        }
    }

    func stopAsk() { runner.cancel() }

    func saveAnswerAsNote() {
        guard !answer.isEmpty else { return }
        if let anchor = chatAnchor {
            addNote(to: anchor, body: answer, ai: true, provider: provider.rawValue)
            return
        }
        editAnnotations("Add Note") {
            let created = AnnotationEdit.addNote(
                toSelection: AnnotationAnchor(text: sectionTitle.isEmpty ? "Page note" : sectionTitle, page: page, section: sectionTitle),
                color: package.state.lastHighlightColor,
                highlightID: nil,
                noteID: IDs.make("n"),
                now: ISO8601DateFormatter().string(from: Date()),
                package: &package
            )
            if let id = created.note?.id {
                AnnotationEdit.updateNoteBody(id: id, body: answer, now: ISO8601DateFormatter().string(from: Date()), package: &package)
            }
        }
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
        let present = {
            self.toast = text
            self.onToast?(text)
            self.toastTimer?.invalidate()
            let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
                self?.toast = nil
                self?.onToast?(nil)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.toastTimer = timer
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async(execute: present)
        }
    }

    private func dirty() {
        captureState()
        if usesVault {
            onVaultFlush?()
        } else {
            onDirty?()
        }
        objectWillChange.send()
    }

    func wordsFromVault(_ entries: [VocabEntry]) {
        package.words.words = entries.map { entry in
            WordEntry(
                id: entry.readerOwned ? entry.id : "hand_\(entry.word.lowercased())",
                word: entry.word,
                definition: entry.meaning,
                explanation: entry.plainLanguage,
                lookups: [LookupEntry(id: "l_\(entry.id)", section: entry.chapter.map { "Chapter \($0)" }, quote: entry.word, sentence: entry.bookContext, date: entry.added)]
            )
        }
    }

    func askAboutConcept(_ concept: Concept) {
        var question = "Ask about \(concept.id) \(concept.title)."
        if let claim = concept.claim { question += " Claim: \(claim)" }
        if let trap = concept.trap { question += " Trap: \(trap)" }
        askTutor(command: nil, question: question)
    }

    func askTutor(command: TutorCommand?, question: String) {
        guard let bookFolder, tutorAvailable else { return }
        let passage = selection?.text ?? ""
        let chapter = ChapterFiles.number(in: selection?.section ?? sectionTitle)
        let nearby = ConceptsFile.suggested(passage: passage, concepts: concepts, chapter: chapter)
        let file = chapter.flatMap { ChapterFiles.chapterTextFile(bookFolder: bookFolder, chapter: $0, fs: LocalFileSystem()) }
        let prompt = TutorPrompt.message(passage: passage, chapter: chapter, chapterFile: file, concepts: nearby, question: question, command: command)
        let event = TutorExchange(
            bookID: Paths.name(bookFolder),
            chapter: chapter,
            conceptIDs: nearby.map(\.id),
            passageCharacterCount: passage.count,
            date: isoDay(Date()),
            eventID: "reader-\(UUID().uuidString.lowercased())"
        )
        let quote = selection?.text ?? ""
        if quote != chatQuote {
            chatQuote = quote
            chatAnchor = selection
            chat = []
        }
        let spoken: String
        if let command {
            spoken = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? command.slash : "\(command.slash) \(question.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            spoken = question
        }
        tutorLines.append("You: \(spoken)")
        chat.append(ReaderChatLine(id: UUID(), mine: true, text: spoken))
        asking = true
        show(tab: .askAI)
        let executable = ClaudeExecutable.resolve(
            override: settings.claudeCLIPath,
            home: NSHomeDirectory(),
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) },
            loginShellPath: { CLILocator.loginCommand("claude") }
        )
        let invocation = ClaudeCommand.tutorInvocation(
            executable: executable,
            prompt: prompt,
            workingDirectory: bookFolder,
            sessionID: claudeSessionID
        )
        let runner = ProcessCommandRunner()
        Task { [weak self] in
            do {
                let result = try runner.run(invocation, timeout: 180) { _ in }
                let text = (try? CLIOutput.parseClaude(result.stdout)) ?? result.stdout
                let resumed = CLIOutput.claudeSessionID(result.stdout)
                await MainActor.run {
                    guard let self else { return }
                    if result.exitCode == 0, !result.timedOut, !result.cancelled {
                        self.appendTutorEvent(event)
                    }
                    if let resumed, !resumed.isEmpty {
                        self.claudeSessionID = resumed
                        self.onSaveVaultState?()
                    }
                    self.answer = text
                    self.tutorLines.append(text)
                    self.chat.append(ReaderChatLine(id: UUID(), mine: false, text: text))
                    self.asking = false
                    self.answerLabel = "Answered by Claude Code in this vault"
                }
            } catch {
                await MainActor.run {
                    self?.tutorLines.append(error.localizedDescription)
                    self?.asking = false
                }
            }
        }
    }

    private func appendTutorEvent(_ event: TutorExchange) {
        guard let bookFolder else { return }
        let path = Paths.join(bookFolder, "learning/events.jsonl")
        let fs = LocalFileSystem()
        try? fs.createDirectory(Paths.parent(path))
        let existing = (try? fs.readString(path)) ?? ""
        let line = event.jsonLine()
        let next = existing.isEmpty || existing.hasSuffix("\n") ? existing + line + "\n" : existing + "\n" + line + "\n"
        try? fs.writeString(path, next)
    }

    private func isoDay(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
        package.state.showMarginNotes = showMarginNotes
    }

    var annotations: [Annotation] {
        AnnotationIndex.items(highlights: highlights, notes: notes)
    }

    var visibleAnnotations: [Annotation] {
        let kind: AnnotationKind
        if annotationFilter == "notes" {
            kind = .notes
        } else if let color = Int(annotationFilter) {
            kind = .color(color)
        } else {
            kind = .all
        }
        let filtered = AnnotationIndex.filter(AnnotationIndex.filter(annotations, kind: kind), query: annotationQuery)
        return AnnotationIndex.sort(filtered, annotationSortRecent ? .recentlyEdited : .position)
    }

    func editAnnotations(_ name: String, _ change: () -> Void) {
        let previousHighlights = package.highlights.highlights
        let previousNotes = package.notes.notes
        let previousColor = package.state.lastHighlightColor
        change()
        undoManager?.registerUndo(withTarget: self) { session in
            session.editAnnotations(name) {
                session.package.highlights.highlights = previousHighlights
                session.package.notes.notes = previousNotes
                session.package.state.lastHighlightColor = previousColor
            }
        }
        undoManager?.setActionName(name)
        annotationRevision += 1
        onAnnotationsChanged?()
        dirty()
    }

    @discardableResult
    func addAnnotationNote() -> Bool {
        guard let selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let anchor = AnnotationAnchor(text: selection.text, page: selection.page, cfi: selection.cfi, section: selection.section ?? sectionTitle, prefix: selection.prefix, suffix: selection.suffix, rects: selection.rects)
        var opened: String?
        editAnnotations("Add Note") {
            let created = AnnotationEdit.addNote(toSelection: anchor, color: package.state.lastHighlightColor, highlightID: IDs.make("h"), noteID: IDs.make("n"), now: ISO8601DateFormatter().string(from: Date()), package: &package)
            opened = created.highlight?.id ?? created.note?.id
        }
        if let opened { onPresentNote?(opened) }
        show(tab: .notes)
        return opened != nil
    }

    func openAnnotation(_ id: String) {
        if let highlight = highlights.first(where: { $0.id == id }), highlight.noteID == nil {
            onPresentNote?(id)
            return
        }
        onPresentNote?(id)
    }

    func beginNoteEdit(id: String) {
        guard noteEditBaseline[id] == nil else { return }
        let linked = highlights.first { $0.id == id }?.noteID
        let body = notes.first { $0.id == id }?.body ?? linked.flatMap { noteID in notes.first { $0.id == noteID }?.body } ?? ""
        noteEditBaseline[id] = body
    }

    func endNoteEdit(id: String) {
        flushNoteBodies()
        let highlight = highlights.first { $0.id == id || $0.noteID == id }
        let candidates = [id, highlight?.noteID, highlight?.id].compactMap { $0 }
        guard let key = candidates.first(where: { noteEditBaseline[$0] != nil }) else { return }
        let original = noteEditBaseline.removeValue(forKey: key) ?? ""
        let noteID = highlight?.noteID ?? (notes.contains { $0.id == id } ? id : nil)
        let current = noteID.flatMap { note in notes.first { $0.id == note }?.body }
        guard let noteID else {
            guard !original.isEmpty else { return }
            undoManager?.registerUndo(withTarget: self) { session in
                session.restoreEditedNote(id: key, body: original)
            }
            undoManager?.setActionName("Edit Note")
            return
        }
        guard current != original else { return }
        undoManager?.registerUndo(withTarget: self) { session in
            session.restoreEditedNote(id: noteID, body: original)
        }
        undoManager?.setActionName("Edit Note")
    }

    private func restoreEditedNote(id: String, body: String) {
        let previous = notes.first(where: { $0.id == id })?.body
        applyPendingNote(id: id, body: body)
        annotationRevision += 1
        onAnnotationsChanged?()
        dirty()
        undoManager?.registerUndo(withTarget: self) { session in
            if let previous {
                session.restoreEditedNote(id: id, body: previous)
            } else {
                session.applyPendingNote(id: id, body: "")
                session.annotationRevision += 1
                session.onAnnotationsChanged?()
                session.dirty()
            }
        }
        undoManager?.setActionName("Edit Note")
    }

    func queueNoteBody(id: String, body: String) {
        pendingNoteBodies[id] = body
        noteSaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.flushNoteBodies()
        }
        RunLoop.main.add(timer, forMode: .common)
        noteSaveTimer = timer
    }

    func flushNoteBodies() {
        noteSaveTimer?.invalidate()
        let pending = pendingNoteBodies
        pendingNoteBodies = [:]
        guard !pending.isEmpty else { return }
        let coalesced = pending.keys.contains { noteEditBaseline[$0] != nil }
        if coalesced {
            for (id, body) in pending { applyPendingNote(id: id, body: body) }
            annotationRevision += 1
            onAnnotationsChanged?()
            dirty()
        } else {
            editAnnotations("Edit Note") {
                for (id, body) in pending { applyPendingNote(id: id, body: body) }
            }
        }
    }

    private func applyPendingNote(id: String, body: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.contains(where: { $0.id == id }) {
            AnnotationEdit.updateNoteBody(id: id, body: body, now: now, package: &package)
            return
        }
        guard let highlight = highlights.first(where: { $0.id == id || $0.noteID == id }) else { return }
        if trimmed.isEmpty {
            if let noteID = highlight.noteID {
                AnnotationEdit.removeNote(id: noteID, package: &package)
            }
            return
        }
        let noteID = highlight.noteID ?? IDs.make("n")
        AnnotationEdit.addNote(toHighlight: highlight.id, noteID: noteID, now: now, package: &package)
        AnnotationEdit.updateNoteBody(id: noteID, body: body, now: now, package: &package)
    }

    func recolorAnnotation(id: String, color: Int) {
        editAnnotations("Recolor Highlight") {
            AnnotationEdit.recolor(id: id, color: color, package: &package)
        }
    }

    func removeNoteOnly(id: String) {
        editAnnotations("Remove Note") {
            if let highlight = highlights.first(where: { $0.id == id }), let noteID = highlight.noteID {
                AnnotationEdit.removeNote(id: noteID, package: &package)
            } else {
                AnnotationEdit.removeNote(id: id, package: &package)
            }
        }
    }

    func deleteSelectedAnnotations() {
        deleteAnnotations(ids: annotationSelection)
    }

    func deleteAnnotations(ids: Set<String>) {
        if deletingAnnotations { return }
        let chosen = annotations.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        deletingAnnotations = true
        defer { deletingAnnotations = false }
        let typed = chosen.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if typed.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Delete \(typed.count) notes?"
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        editAnnotations(chosen.count == 1 ? "Delete" : "Delete Annotations") {
            AnnotationEdit.remove(ids: ids, package: &package)
        }
        annotationSelection.subtract(ids)
    }

    func recolorAnnotations(ids: Set<String>, color: Int) {
        editAnnotations("Recolor") {
            AnnotationEdit.recolor(ids: ids, color: color, package: &package)
        }
    }

    func exportAnnotations(_ items: [Annotation]) {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Notes.md"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            try? self.annotationMarkdown(items).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func removeAnnotationCompletely(id: String) {
        editAnnotations("Remove Highlight") {
            if highlights.contains(where: { $0.id == id }) {
                AnnotationEdit.removeHighlightAndNote(id: id, package: &package)
            } else {
                AnnotationEdit.removeNote(id: id, package: &package)
            }
        }
    }

    func toggleMarginNotes() {
        showMarginNotes.toggle()
        package.state.showMarginNotes = showMarginNotes
        onAnnotationsChanged?()
        saveViewQuietly()
    }

    func annotationMarkdown(_ items: [Annotation]) -> String {
        AnnotationExport.markdown(book: bookURL.deletingPathExtension().lastPathComponent, items: items, path: bookURL.path)
    }

    private func locationLabel(_ selection: SelectionContext) -> String {
        if let page = selection.page { return "p. \(page)" }
        if let section = selection.section { return section }
        return sectionTitle
    }

    /// The stored location of the current section in a web document.
    func currentLocation() -> String? {
        if let markdown {
            let index = min(max(page - 1, 0), max(markdown.sections.count - 1, 0))
            guard markdown.sections.indices.contains(index) else { return nil }
            return MarkdownAnchor.make(sectionIndex: index, anchorID: markdown.sections[index].anchorID).rawValue
        }
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

    private func loadMarkdown() {
        let source = String(decoding: bookData, as: UTF8.self)
        let model = MarkdownDocumentModel.parse(source: source, fileName: bookURL.lastPathComponent)
        markdown = model
        pageCount = max(model.sections.count, 1)
        page = min(page, pageCount)
        outline = model.headings.enumerated().map { index, heading in
            OutlineRow(id: "md-\(index)-\(heading.id)", title: heading.title, page: nil,
                       cfi: MarkdownAnchor.make(sectionIndex: heading.sectionIndex, anchorID: heading.id).rawValue,
                       depth: max(heading.level - 1, 0))
        }
        sectionTitle = model.sections.indices.contains(page - 1) ? model.sections[page - 1].title : model.title
        bookText = model.bookText()
    }

    func reloadMarkdown(data: Data) {
        bookData = data
        fingerprint = SHA256.fingerprint(data)
        loadMarkdown()
        onPageChange?()
    }

    private func prepareBookText() {
        // Markdown parses quickly and changes on disk, so its text is never cached.
        if isMarkdown { return }
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
