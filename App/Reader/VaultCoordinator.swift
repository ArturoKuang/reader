import AppKit
import Foundation
import ReaderCore

/// Reads and writes a book's notes inside an Obsidian vault. Sidecar packages stay in use
/// for books that are not in a vault, or when the per-book toggle is off.
final class VaultCoordinator {
    let location: VaultLocation
    private(set) var settings: VaultBookSettings
    private let fs = LocalFileSystem()
    private var watcher: VaultFolderWatcher?
    private var flushTimer: Timer?
    private var lastWritten: [String: String] = [:]
    private var loadedBlockIDs: Set<String> = []
    private var applyingOwnWrite = false

    init(location: VaultLocation, settings: VaultBookSettings) {
        self.location = location
        self.settings = settings
    }

    static func make(bookPath: String) -> VaultCoordinator? {
        let fs = LocalFileSystem()
        guard let location = VaultFinder.locate(bookPath: bookPath, fs: fs) else { return nil }
        var settings = VaultBookSettings.load(bookFolder: location.bookFolder, fs: fs)
        if !fs.exists(Paths.join(location.bookFolder, ".reader-state.json")) {
            settings.enabled = true
        }
        guard settings.enabled else { return nil }
        return VaultCoordinator(location: location, settings: settings)
    }

    func attach(_ session: ReaderSession) {
        session.usesVault = true
        session.vaultName = location.vaultName
        session.vaultRoot = location.vaultRoot
        session.bookFolder = location.bookFolder
        session.showConceptMarkers = settings.showConceptMarkers
        session.vaultNotesFolder = settings.notesFolder
        session.vaultVocabularyFile = settings.vocabularyFile ?? ""
        session.vaultEnabled = settings.enabled
        session.tutorAvailable = fs.exists(Paths.join(location.bookFolder, "CLAUDE.md"))
        session.claudeSessionID = settings.claudeSessionID
        reload(into: session, mergePending: false)
        session.onVaultFlush = { [weak self, weak session] in
            guard let self, let session else { return }
            self.scheduleFlush(session)
        }
        session.onSaveVaultState = { [weak self, weak session] in
            guard let self, let session else { return }
            self.settings.view = session.package.state
            self.settings.showConceptMarkers = session.showConceptMarkers
            self.settings.claudeSessionID = session.claudeSessionID
            self.settings.enabled = session.vaultEnabled
            self.settings.notesFolder = session.vaultNotesFolder.isEmpty ? "notes" : session.vaultNotesFolder
            self.settings.vocabularyFile = session.vaultVocabularyFile.isEmpty ? nil : session.vaultVocabularyFile
            try? self.settings.save(bookFolder: self.location.bookFolder, fs: self.fs)
        }
        session.onInsertConcept = { [weak self] concept in
            self?.ensureConceptStub(concept)
        }
        watcher = VaultFolderWatcher(bookFolder: location.bookFolder) { [weak self, weak session] in
            guard let self, let session, !self.applyingOwnWrite else { return }
            self.reload(into: session, mergePending: true)
        }
    }

    func reload(into session: ReaderSession, mergePending: Bool) {
        let concepts = loadConcepts()
        session.concepts = concepts
        session.mastery = loadMastery()
        let notesDir = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
        var notes: [NoteEntry] = []
        var highlights: [HighlightEntry] = []
        var ids: Set<String> = []
        if let files = try? fs.list(notesDir) {
            for name in files where name.hasSuffix(".md") {
                let path = Paths.join(notesDir, name)
                guard let text = try? fs.readString(path) else { continue }
                let chapter = ChapterFiles.number(in: name)
                for block in VaultNoteFile.blocks(text) {
                    ids.insert(block.id)
                    if let color = block.color {
                        highlights.append(HighlightEntry(id: block.id, color: color, page: nil, cfi: block.link.location, quote: block.quote, section: chapter.map { "Chapter \($0)" }, noteID: block.body.isEmpty ? nil : block.id))
                    } else {
                        notes.append(NoteEntry(id: block.id, cfi: block.link.location, quote: block.quote, section: chapter.map { "Chapter \($0)" }, body: block.body))
                    }
                }
            }
        }
        if mergePending {
            for note in session.notes where !ids.contains(note.id) {
                notes.append(note)
            }
        }
        session.package.notes.notes = notes
        session.package.highlights.highlights = highlights
        loadedBlockIDs = ids
        session.wordsFromVault(loadVocabulary(title: session.bookURL.deletingPathExtension().lastPathComponent))
        session.objectWillChange.send()
        session.onAnnotationsChanged?()
    }

    func scheduleFlush(_ session: ReaderSession) {
        flushTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.flush(session)
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    func flush(_ session: ReaderSession) {
        applyingOwnWrite = true
        defer { applyingOwnWrite = false }
        writeNotes(session)
        writeWords(session)
        settings.view = session.package.state
        settings.claudeSessionID = session.claudeSessionID
        settings.showConceptMarkers = session.showConceptMarkers
        try? settings.save(bookFolder: location.bookFolder, fs: fs)
    }

    func reveal(id: String, chapter: Int?) {
        let file = Paths.join(settings.notesFolder, ChapterFiles.notesFile(chapter: chapter, bookTitle: ""))
        let url = URL(string: ObsidianLink.open(vault: location.vaultName, file: file, blockID: id))
        if let url { NSWorkspace.shared.open(url) }
    }

    func ensureConceptStub(_ concept: Concept) {
        let directory = Paths.join(location.bookFolder, "concepts")
        let path = Paths.join(directory, concept.stubFileName)
        if fs.exists(path) { return }
        try? fs.createDirectory(directory)
        try? fs.writeString(path, ConceptsFile.stub(for: concept))
    }

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        try? settings.save(bookFolder: location.bookFolder, fs: fs)
    }

    func updateMapping(notesFolder: String, vocabularyFile: String?) {
        settings.notesFolder = notesFolder.isEmpty ? "notes" : notesFolder
        settings.vocabularyFile = vocabularyFile?.isEmpty == true ? nil : vocabularyFile
        try? settings.save(bookFolder: location.bookFolder, fs: fs)
    }

    private func writeNotes(_ session: ReaderSession) {
        let directory = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
        try? fs.createDirectory(directory)
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        var grouped: [String: [VaultNoteBlock]] = [:]
        for note in session.notes {
            let chapter = ChapterFiles.number(in: note.section ?? "")
            let name = ChapterFiles.notesFile(chapter: chapter, bookTitle: title)
            grouped[name, default: []].append(block(id: note.id, quote: note.quote, body: note.body, color: nil, session: session, chapter: chapter))
        }
        for highlight in session.highlights {
            let chapter = ChapterFiles.number(in: highlight.section ?? "")
            let name = ChapterFiles.notesFile(chapter: chapter, bookTitle: title)
            let note = highlight.noteID.flatMap { id in session.notes.first { $0.id == id }?.body } ?? ""
            grouped[name, default: []].append(block(id: highlight.id, quote: highlight.quote, body: note, color: highlight.color, session: session, chapter: chapter))
        }
        var touched: Set<String> = []
        for (name, blocks) in grouped {
            let path = Paths.join(directory, name)
            var text = (try? fs.readString(path)) ?? ""
            for item in blocks {
                text = VaultNoteFile.upsert(text, block: item)
                loadedBlockIDs.insert(item.id)
            }
            writeIfChanged(path, text)
            touched.insert(path)
        }
        if let names = try? fs.list(directory) {
            for name in names where name.hasSuffix(".md") {
                let path = Paths.join(directory, name)
                var text = (try? fs.readString(path)) ?? ""
                let keep = Set((grouped[name] ?? []).map(\.id))
                var changed = false
                for id in OwnedBlocks.parse(text).compactMap(\.id) where loadedBlockIDs.contains(id) && !keep.contains(id) {
                    text = OwnedBlocks.remove(text, id: id)
                    changed = true
                }
                if changed { writeIfChanged(path, text) }
            }
        }
    }

    private func writeWords(_ session: ReaderSession) {
        let path = VaultPaths.vocabularyFile(bookFolder: location.bookFolder, settings: settings, fs: fs)
        var text = (try? fs.readString(path)) ?? ""
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        for word in session.words where word.id.hasPrefix("w_") {
            let added = LongDate.format(year: Calendar.current.component(.year, from: Date()), month: Calendar.current.component(.month, from: Date()), day: Calendar.current.component(.day, from: Date()))
            let entry = VocabEntry(
                id: word.id,
                word: word.word,
                chapter: word.lookups.first?.section.flatMap { ChapterFiles.number(in: $0) },
                meaning: word.definition,
                bookContext: word.lookups.first?.sentence ?? word.lookups.first?.quote ?? word.word,
                plainLanguage: word.explanation,
                example: nil,
                added: added,
                readerOwned: true
            )
            text = VocabularyFile.upsert(text, title: title, entry: entry)
        }
        try? fs.createDirectory(Paths.parent(path))
        writeIfChanged(path, text)
    }

    private func writeIfChanged(_ path: String, _ text: String) {
        if lastWritten[path] == text { return }
        if (try? fs.readString(path)) == text { lastWritten[path] = text; return }
        applyingOwnWrite = true
        try? fs.writeString(path, text)
        lastWritten[path] = text
    }

    private func block(id: String, quote: String, body: String, color: Int?, session: ReaderSession, chapter: Int?) -> VaultNoteBlock {
        let location = session.selection?.cfi ?? session.selection?.page.map { "page=\($0)" }
        let link = ReaderLink(path: session.bookURL.path, location: location, id: id)
        return VaultNoteBlock(id: id, quote: quote, body: body, color: color, link: link, chapter: chapter)
    }

    private func loadVocabulary(title: String) -> [VocabEntry] {
        let path = VaultPaths.vocabularyFile(bookFolder: location.bookFolder, settings: settings, fs: fs)
        guard let text = try? fs.readString(path) else { return [] }
        return VocabularyFile.parse(text)
    }

    private func loadConcepts() -> [Concept] {
        let path = Paths.join(location.bookFolder, "curriculum/concepts.md")
        guard let text = try? fs.readString(path) else { return [] }
        return ConceptsFile.parse(text)
    }

    private func loadMastery() -> [String: MasteryRecord] {
        let path = Paths.join(location.bookFolder, "learner/mastery.json")
        guard let text = try? fs.readString(path) else { return [:] }
        return MasteryFile.parse(text)
    }
}

final class VaultFolderWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var timer: Timer?
    private let onChange: () -> Void

    init(bookFolder: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let paths = [
            bookFolder,
            Paths.join(bookFolder, "notes"),
            Paths.join(bookFolder, "learner"),
            Paths.join(bookFolder, "learner/vocabulary.md"),
            Paths.join(bookFolder, "learner/mastery.json"),
            Paths.join(bookFolder, "curriculum/concepts.md"),
            Paths.join(bookFolder, "learning/events.jsonl"),
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let fd = open(path, O_EVTONLY)
            if fd < 0 { continue }
            descriptors.append(fd)
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in self?.schedule() }
            source.resume()
            sources.append(source)
        }
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in self?.onChange() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        sources.forEach { $0.cancel() }
        descriptors.forEach { close($0) }
    }
}
