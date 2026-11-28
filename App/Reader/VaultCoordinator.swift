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
    private var loadedWords: [String: String] = [:]
    private var applyingOwnWrite = false

    init(location: VaultLocation, settings: VaultBookSettings) {
        self.location = location
        self.settings = settings
    }

    static func make(bookPath: String, linkedFolder: String? = nil) -> (coordinator: VaultCoordinator?, notice: String?) {
        let fs = LocalFileSystem()
        let location: VaultLocation
        switch VaultFinder.resolve(bookPath: bookPath, linkedFolder: linkedFolder, fs: fs) {
        case .vault(let found):
            location = found
        case .missingLink(let path):
            return (nil, "The linked vault folder \(path) is missing. Notes stay in the sidecar.")
        case .none:
            return (nil, nil)
        }
        var settings = VaultBookSettings.load(bookFolder: location.bookFolder, fs: fs)
        if !fs.exists(Paths.join(location.bookFolder, ".reader-state.json")) {
            settings.enabled = VaultFinder.classify(bookFolder: location.bookFolder, fs: fs) == .bookFolder
        }
        return (VaultCoordinator(location: location, settings: settings), nil)
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
        session.vaultLoose = VaultFinder.classify(bookFolder: location.bookFolder, fs: fs) == .loose
        session.tutorAvailable = fs.exists(Paths.join(location.bookFolder, "CLAUDE.md"))
        if session.tutorAvailable, session.askChoice.isEmpty { session.askChoice = "tutor" }
        session.claudeSessionID = settings.claudeSessionID
        reload(into: session, mergePending: false)
        session.onVaultFlush = { [weak self, weak session] in
            guard let self, let session, self.settings.enabled else { return }
            self.scheduleFlush(session)
        }
        session.onVaultSave = { [weak self, weak session] in
            guard let self, let session, self.settings.enabled else { return }
            self.flushTimer?.invalidate()
            self.flushTimer = nil
            self.flush(session)
        }
        session.onSaveVaultState = { [weak self, weak session] in
            guard let self, let session else { return }
            let wasWriting = self.settings.enabled
            self.settings.view = session.package.state
            self.settings.showConceptMarkers = session.showConceptMarkers
            self.settings.claudeSessionID = session.claudeSessionID
            self.settings.enabled = session.vaultEnabled
            if Paths.isSafeRelative(session.vaultNotesFolder) {
                self.settings.notesFolder = session.vaultNotesFolder
            }
            if session.vaultVocabularyFile.isEmpty || Paths.isSafeRelative(session.vaultVocabularyFile) {
                self.settings.vocabularyFile = session.vaultVocabularyFile.isEmpty ? nil : session.vaultVocabularyFile
            }
            self.holdOwnWrite()
            try? self.settings.save(bookFolder: self.location.bookFolder, fs: self.fs)
            if self.settings.enabled {
                if !wasWriting || self.watcher == nil { self.installWatcher(session) }
            } else {
                self.watcher = nil
            }
        }
        session.onRelocateNotes = { [weak self, weak session] from, to, move in
            guard let self, let session, Paths.isSafeRelative(to) else { return }
            let oldDir = Paths.join(self.location.bookFolder, from)
            let newDir = Paths.join(self.location.bookFolder, to)
            if move, FileManager.default.fileExists(atPath: oldDir), !FileManager.default.fileExists(atPath: newDir) {
                try? FileManager.default.createDirectory(atPath: Paths.parent(newDir), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(atPath: oldDir, toPath: newDir)
            }
            session.vaultNotesFolder = to
            self.settings.notesFolder = to
            self.holdOwnWrite()
            try? self.settings.save(bookFolder: self.location.bookFolder, fs: self.fs)
            self.installWatcher(session)
        }
        session.onInsertConcept = { [weak self] concept in
            self?.ensureConceptStub(concept)
        }
        installWatcher(session)
    }

    private func holdOwnWrite() {
        applyingOwnWrite = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.applyingOwnWrite = false
        }
    }

    private func installWatcher(_ session: ReaderSession) {
        watcher = nil
        guard settings.enabled else { return }
        let notes = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
        let vocabulary = VaultPaths.vocabularyFile(bookFolder: location.bookFolder, settings: settings, fs: fs)
        watcher = VaultFolderWatcher(bookFolder: location.bookFolder, notesDirectory: notes, vocabularyFile: vocabulary) { [weak self, weak session] in
            guard let self, let session, !self.applyingOwnWrite, self.settings.enabled else { return }
            self.reload(into: session, mergePending: true)
        }
    }

    func reload(into session: ReaderSession, mergePending: Bool) {
        let concepts = loadConcepts()
        session.concepts = concepts
        session.mastery = loadMastery()
        let notesDir = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
        let keptRects = Dictionary(session.highlights.map { ($0.id, $0.rects) }, uniquingKeysWith: { first, _ in first })
        var notes: [NoteEntry] = []
        var highlights: [HighlightEntry] = []
        var ids: Set<String> = []
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        if let files = try? fs.list(notesDir) {
            for name in files where name.hasSuffix(".md") {
                let path = Paths.join(notesDir, name)
                guard var text = try? fs.readString(path) else { continue }
                if mergePending, !VaultSync.isOwnWrite(newDisk: text, lastWritten: lastWritten[path]) {
                    text = mergeExternal(text, path: path, fileName: name, title: title, session: session)
                }
                let chapter = ChapterFiles.number(in: name)
                for block in VaultNoteFile.blocks(text) {
                    ids.insert(block.id)
                    let page = block.link.pageNumber
                    let rects = keptRects[block.id] ?? []
                    let storedCFI = PassageIdentity.cfi(block.link.location)
                    let hasBody = !block.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if let color = block.color {
                        let sessionNoteID = session.highlights.first { $0.id == block.id }?.noteID
                        let noteID = sessionNoteID ?? (hasBody ? block.id : nil)
                        highlights.append(HighlightEntry(id: block.id, color: color, page: page, cfi: storedCFI, quote: block.quote, section: chapter.map { "Chapter \($0)" }, rects: rects, noteID: noteID))
                        if hasBody {
                            let noteIdentity = noteID ?? block.id
                            notes.append(NoteEntry(id: noteIdentity, page: page, cfi: storedCFI, quote: block.quote, section: chapter.map { "Chapter \($0)" }, body: block.body))
                            ids.insert(noteIdentity)
                        } else if let noteID, let existing = session.notes.first(where: { $0.id == noteID }) {
                            var kept = existing
                            kept.cfi = PassageIdentity.cfi(kept.cfi)
                            kept.page = kept.page ?? page
                            notes.append(kept)
                            ids.insert(noteID)
                        }
                    } else if hasBody {
                        notes.append(NoteEntry(id: block.id, page: page, cfi: storedCFI, quote: block.quote, section: chapter.map { "Chapter \($0)" }, body: block.body))
                    }
                }
            }
        }
        if mergePending {
            for note in session.notes where !ids.contains(note.id) {
                let alreadyShown = highlights.contains { PassageIdentity.same(quote: $0.quote, page: $0.page, cfi: $0.cfi, otherQuote: note.quote, otherPage: note.page, otherCFI: note.cfi) }
                    || notes.contains { PassageIdentity.same(quote: $0.quote, page: $0.page, cfi: $0.cfi, otherQuote: note.quote, otherPage: note.page, otherCFI: note.cfi) }
                if alreadyShown { continue }
                notes.append(note)
            }
        }
        AnnotationEdit.dropDuplicateNotes(highlights: &highlights, notes: &notes)
        session.package.notes.notes = notes
        session.package.highlights.highlights = highlights
        loadedBlockIDs = ids
        let vocab = loadVocabulary(title: session.bookURL.deletingPathExtension().lastPathComponent)
        loadedWords = Dictionary(vocab.map { entry in
            let id = entry.readerOwned ? entry.id : "hand_\(entry.word.lowercased())"
            return (id, entry.word)
        }, uniquingKeysWith: { first, _ in first })
        session.wordsFromVault(vocab)
        session.objectWillChange.send()
        session.publishAnnotationsChanged()
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
        guard settings.enabled else { return }
        holdOwnWrite()
        writeNotes(session)
        writeWords(session)
        settings.view = session.package.state
        settings.claudeSessionID = session.claudeSessionID
        settings.showConceptMarkers = session.showConceptMarkers
        session.persistVaultMarks()
        try? settings.save(bookFolder: location.bookFolder, fs: fs)
    }

    func reveal(id: String, chapter: Int?) {
        let file = ObsidianLink.noteFile(
            vaultRoot: location.vaultRoot,
            bookFolder: location.bookFolder,
            notesFolder: settings.notesFolder,
            chapter: chapter,
            bookTitle: ""
        )
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

    private func mergeExternal(_ disk: String, path: String, fileName: String, title: String, session: ReaderSession) -> String {
        let baseline = lastWritten[path] ?? disk
        var pending: [String: String] = [:]
        var written: [String: String] = [:]
        func consider(id: String, body: String) {
            pending[id] = body
            if let previous = OwnedBlocks.body(id: id, in: baseline) { written[id] = previous }
        }
        for note in session.notes where ChapterFiles.notesFile(chapter: ChapterFiles.number(in: note.section ?? ""), bookTitle: title) == fileName {
            consider(id: note.id, body: block(id: note.id, quote: note.quote, body: note.body, color: nil, path: session.bookURL.path, location: anchor(cfi: note.cfi, page: note.page), chapter: ChapterFiles.number(in: note.section ?? "")).markdown())
        }
        for highlight in session.highlights where ChapterFiles.notesFile(chapter: ChapterFiles.number(in: highlight.section ?? ""), bookTitle: title) == fileName {
            let note = highlight.noteID.flatMap { id in session.notes.first { $0.id == id }?.body } ?? ""
            consider(id: highlight.id, body: block(id: highlight.id, quote: highlight.quote, body: note, color: highlight.color, path: session.bookURL.path, location: anchor(cfi: highlight.cfi, page: highlight.page), chapter: ChapterFiles.number(in: highlight.section ?? "")).markdown())
        }
        let applied = VaultSync.applyExternal(VaultSyncState(disk: baseline, pending: pending, written: written), disk: disk)
        if !applied.conflicts.isEmpty {
            session.showToast("Kept both versions of a note")
            writeIfChanged(path, applied.state.disk)
        }
        return applied.state.disk
    }

    private func writeNotes(_ session: ReaderSession) {
        let directory = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
        try? fs.createDirectory(directory)
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        var grouped: [String: [Annotation]] = [:]
        for item in AnnotationIndex.items(highlights: session.highlights, notes: session.notes) {
            let chapter = ChapterFiles.number(in: item.section ?? "")
            let name = ChapterFiles.notesFile(chapter: chapter, bookTitle: title)
            grouped[name, default: []].append(item)
        }
        var names = Set(grouped.keys)
        if let existing = try? fs.list(directory) {
            for name in existing where name.hasSuffix(".md") { names.insert(name) }
        }
        let explicitlyDeleted = session.deletedAnnotationIDs
        for name in names {
            let path = Paths.join(directory, name)
            let text = (try? fs.readString(path)) ?? ""
            let items = grouped[name] ?? []
            let keep = Set(items.map(\.id))
            let present = Set(OwnedBlocks.parse(text).compactMap(\.id))
            let remove = present.intersection(loadedBlockIDs.union(explicitlyDeleted)).subtracting(keep)
            if items.isEmpty, remove.isEmpty { continue }
            let written = VaultAnnotationSync.render(existing: text, bookPath: session.bookURL.path, annotations: items, removeIDs: remove)
            loadedBlockIDs.subtract(remove)
            for item in items { loadedBlockIDs.insert(item.id) }
            writeIfChanged(path, written)
        }
        session.deletedAnnotationIDs.subtract(explicitlyDeleted)
    }

    private func writeWords(_ session: ReaderSession) {
        let path = VaultPaths.vocabularyFile(bookFolder: location.bookFolder, settings: settings, fs: fs)
        var text = (try? fs.readString(path)) ?? ""
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        let liveIDs = Set(session.words.map(\.id))
        let removedFromLoaded = Set(loadedWords.keys).subtracting(liveIDs)
        let explicitRemoved = session.deletedWordIDs.subtracting(liveIDs)
        let removedIDs = removedFromLoaded.union(explicitRemoved)
        for id in removedIDs {
            let wordName = loadedWords[id] ?? session.deletedWordNames[id]
            text = VocabularyFile.remove(text, id: id, word: wordName)
            loadedWords.removeValue(forKey: id)
            session.deletedWordIDs.remove(id)
            session.deletedWordNames.removeValue(forKey: id)
        }
        for word in session.words where word.id.hasPrefix("w_") {
            let added = LongDate.format(year: Calendar.current.component(.year, from: Date()), month: Calendar.current.component(.month, from: Date()), day: Calendar.current.component(.day, from: Date()))
            let lookup = word.lookups.first
            let entry = VocabEntry(
                id: word.id,
                word: word.word,
                chapter: lookup?.section.flatMap { ChapterFiles.number(in: $0) },
                page: lookup?.page,
                meaning: VocabularyFile.shortMeaning(word.definition),
                bookContext: word.lookups.first?.sentence ?? word.lookups.first?.quote ?? word.word,
                plainLanguage: word.explanation,
                example: nil,
                added: added,
                readerOwned: true
            )
            text = VocabularyFile.upsert(text, title: title, entry: entry)
            loadedWords[word.id] = word.word
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
        applyingOwnWrite = false
    }

    private func anchor(cfi: String?, page: Int?) -> String? {
        if let cfi, !cfi.isEmpty { return cfi }
        if let page { return "page=\(page)" }
        return nil
    }

    private func block(id: String, quote: String, body: String, color: Int?, path: String, location: String?, chapter: Int?) -> VaultNoteBlock {
        VaultNoteBlock(id: id, quote: quote, body: body, color: color, link: ReaderLink(path: path, location: location, id: id), chapter: chapter)
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

    init(bookFolder: String, notesDirectory: String, vocabularyFile: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let paths = [
            bookFolder,
            notesDirectory,
            Paths.parent(vocabularyFile),
            vocabularyFile,
            Paths.join(bookFolder, "learner"),
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
