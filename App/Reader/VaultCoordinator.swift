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
    /// Each vault file as Reader last read or wrote it: the base of the next merge.
    private var known: [String: String] = [:]
    private var loadedBlockIDs: Set<String> = []
    private var loadedWords: [String: String] = [:]
    private var needsFlush = false
    private var needsRelocation = false
    /// Non-nil while Reader's own write may still be echoing through the watcher.
    private var ownWrite: UUID?

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

    private var openBook: URL?

    func attach(_ session: ReaderSession) {
        openBook = session.bookURL
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
        session.vaultFallbackState = { [weak self] in
            PausedVaultState(authoritative: true, baseline: self?.known ?? [:], blockIDs: self?.loadedBlockIDs.sorted() ?? [])
        }
        session.onVaultFlushNow = { [weak self, weak session] force in
            guard let self, let session, force || self.needsFlush else { return }
            try self.flush(session)
        }
        session.onVaultRelocate = { [weak self, weak session] in
            guard let self, let session else { return }
            self.needsRelocation = true
            self.flushReportingErrors(session)
        }
        session.onVaultFlush = { [weak self, weak session] in
            guard let self, let session, self.settings.enabled else { return }
            self.scheduleFlush(session)
        }
        session.onVaultSave = { [weak self, weak session] in
            guard let self, let session, self.settings.enabled else { return }
            self.flushReportingErrors(session)
        }
        session.onSaveVaultState = { [weak self, weak session] in
            guard let self, let session else { return }
            let wasWriting = self.settings.enabled
            let isWriting = session.vaultEnabled
            // Anything changed before pausing still belongs in the vault.
            if wasWriting, !isWriting, self.needsFlush { self.flushReportingErrors(session) }
            self.settings.view = session.package.state
            self.settings.showConceptMarkers = session.showConceptMarkers
            self.settings.claudeSessionID = session.claudeSessionID
            self.settings.enabled = isWriting
            if Paths.isSafeRelative(session.vaultNotesFolder) {
                self.settings.notesFolder = session.vaultNotesFolder
            }
            if session.vaultVocabularyFile.isEmpty || Paths.isSafeRelative(session.vaultVocabularyFile) {
                self.settings.vocabularyFile = session.vaultVocabularyFile.isEmpty ? nil : session.vaultVocabularyFile
            }
            self.holdOwnWrite()
            try? self.settings.save(bookFolder: self.location.bookFolder, fs: self.fs)
            if wasWriting, !isWriting {
                self.pauseSaving(session)
            } else if !wasWriting, isWriting {
                self.resumeSaving(session)
            } else if isWriting, self.watcher == nil {
                self.installWatcher(session)
            }
        }
        session.onRelocateNotes = { [weak self, weak session] from, to, move in
            guard let self, let session, Paths.isSafeRelative(to) else { return }
            let oldDir = Paths.join(self.location.bookFolder, from)
            let newDir = Paths.join(self.location.bookFolder, to)
            if move, FileManager.default.fileExists(atPath: oldDir), !FileManager.default.fileExists(atPath: newDir) {
                try? FileManager.default.createDirectory(atPath: Paths.parent(newDir), withIntermediateDirectories: true)
                if (try? FileManager.default.moveItem(atPath: oldDir, toPath: newDir)) != nil {
                    for (path, text) in self.known where Paths.parent(path) == oldDir {
                        self.known[Paths.join(newDir, Paths.name(path))] = text
                    }
                }
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
        restoreFallback(into: session)
        installWatcher(session)
    }

    /// Brings back notes that were saved beside the book while the vault was not being written.
    private func restoreFallback(into session: ReaderSession) {
        guard fs.isDirectory(session.directory),
              let sidecar = try? SidecarPackage.read(from: session.directory, fs: fs) else { return }
        guard let state = PausedVaultState.load(directory: session.directory, fs: fs) else {
            // A package from before the book was in the vault. Keep its entries before writing over it.
            if !settings.enabled { session.package.mergeAnnotations(from: sidecar) }
            return
        }
        guard state.authoritative else { return }
        session.package.notes.notes = sidecar.notes.notes
        session.package.highlights.highlights = sidecar.highlights.highlights
        session.package.words.words = sidecar.words.words
        session.package.marks.marks = sidecar.marks.marks
        known = state.baseline
        loadedBlockIDs = Set(state.blockIDs)
        if settings.enabled { resumeSaving(session) }
    }

    private func pauseSaving(_ session: ReaderSession) {
        watcher = nil
        flushTimer?.invalidate()
        if PausedVaultState.load(directory: session.directory, fs: fs) == nil,
           fs.isDirectory(session.directory),
           let sidecar = try? SidecarPackage.read(from: session.directory, fs: fs) {
            session.package.mergeAnnotations(from: sidecar)
        }
        session.markSidecarChanged()
        do {
            try session.persistSidecar()
        } catch {
            session.notice = error.localizedDescription
        }
    }

    private func resumeSaving(_ session: ReaderSession) {
        needsFlush = true
        do {
            try flush(session)
            if fs.isDirectory(session.directory) {
                try PausedVaultState(authoritative: false).save(directory: session.directory, fs: fs)
            }
            // Picks up blocks that only the vault has.
            reload(into: session, mergePending: true)
        } catch {
            session.notice = error.localizedDescription
        }
        installWatcher(session)
    }

    private func holdOwnWrite() {
        let token = UUID()
        ownWrite = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            if self?.ownWrite == token { self?.ownWrite = nil }
        }
    }

    private func installWatcher(_ session: ReaderSession) {
        watcher = nil
        guard settings.enabled else { return }
        let notes = VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
        let vocabulary = VaultPaths.vocabularyFile(bookFolder: location.bookFolder, settings: settings, fs: fs)
        watcher = VaultFolderWatcher(bookFolder: location.bookFolder, notesDirectory: notes, vocabularyFile: vocabulary) { [weak self, weak session] in
            guard let self, let session, self.settings.enabled else { return }
            // Reader's own writes match what it already knows.
            if self.ownWrite != nil, !self.notesChangedOnDisk() { return }
            self.reload(into: session, mergePending: true)
        }
    }

    private var notesDirectory: String {
        VaultPaths.notesDirectory(bookFolder: location.bookFolder, settings: settings)
    }

    private func noteFileNames() -> Set<String> {
        Set(((try? fs.list(notesDirectory)) ?? []).filter { $0.hasSuffix(".md") })
    }

    private func notesChangedOnDisk() -> Bool {
        let directory = notesDirectory
        let tracked = known.keys.filter { Paths.parent($0) == directory }.map { Paths.name($0) }
        return noteFileNames().union(tracked).contains { name in
            let path = Paths.join(directory, name)
            return ((try? fs.readString(path)) ?? "") != (known[path] ?? "")
        }
    }

    /// Reader's annotations by note file. A standalone note that is still empty has no block.
    private func annotationsByFile(_ session: ReaderSession) -> [String: [Annotation]] {
        let title = session.bookURL.deletingPathExtension().lastPathComponent
        var grouped: [String: [Annotation]] = [:]
        for item in AnnotationIndex.items(highlights: session.highlights, notes: session.notes) {
            if item.highlight == nil, AnnotationEdit.isBlankNote(item.body) { continue }
            let chapter = ChapterFiles.number(in: item.section ?? "")
            grouped[ChapterFiles.notesFile(chapter: chapter, bookTitle: title), default: []].append(item)
        }
        return grouped
    }

    /// Blocks Reader loaded, wrote, or was told to delete that it no longer has.
    private func removedIDs(in text: String, keeping items: [Annotation], explicitlyDeleted: Set<String> = []) -> Set<String> {
        Set(OwnedBlocks.parse(text).compactMap(\.id)).intersection(loadedBlockIDs.union(explicitlyDeleted)).subtracting(items.map(\.id))
    }

    /// Reads the vault into the session. With `mergePending`, Reader's unsaved changes and the changes
    /// on disk are merged block by block first.
    func reload(into session: ReaderSession, mergePending: Bool) {
        if mergePending { session.flushNoteBodies() }
        session.concepts = loadConcepts()
        session.mastery = loadMastery()
        let directory = notesDirectory
        let mine = mergePending ? annotationsByFile(session) : [:]
        // A file that does not exist yet still needs the annotations that were never written.
        let unwritten = mine.filter { _, items in items.contains { !loadedBlockIDs.contains($0.id) } }.keys
        var files: [(name: String, text: String)] = []
        var conflicted = false
        for name in noteFileNames().union(unwritten).sorted() {
            let path = Paths.join(directory, name)
            let disk: String
            if fs.exists(path) {
                guard let read = try? fs.readString(path) else { continue }
                disk = read
            } else {
                disk = ""
            }
            var text = disk
            known[path] = known[path] ?? (mergePending ? "" : disk)
            if mergePending {
                let items = mine[name] ?? []
                let base = known[path] ?? ""
                let merged = VaultAnnotationSync.merge(baseline: base, disk: disk, bookPath: session.bookURL.path, annotations: items, removeIDs: removedIDs(in: base, keeping: items))
                text = merged.text
                conflicted = conflicted || !merged.conflicts.isEmpty
                if text != disk {
                    holdOwnWrite()
                    do {
                        try writeIfChanged(path, text)
                    } catch {
                        session.notice = error.localizedDescription
                    }
                }
            }
            known[path] = text
            files.append((name, text))
        }
        if conflicted { session.showToast("Kept both versions of a note") }
        apply(files, to: session)
        if mergePending, needsFlush { try? writeWords(session) }
        let vocab = loadVocabulary(title: session.bookURL.deletingPathExtension().lastPathComponent)
        loadedWords = Dictionary(vocab.map { entry in
            let id = entry.readerOwned ? entry.id : "hand_\(entry.word.lowercased())"
            return (id, entry.word)
        }, uniquingKeysWith: { first, _ in first })
        session.wordsFromVault(vocab)
        session.revokeStaleNoteEdits()
        session.objectWillChange.send()
        session.publishAnnotationsChanged()
    }

    private func apply(_ files: [(name: String, text: String)], to session: ReaderSession) {
        let oldHighlights = Dictionary(session.highlights.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldNotes = Dictionary(session.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var notes: [NoteEntry] = []
        var highlights: [HighlightEntry] = []
        var ids: Set<String> = []
        /// The vault stores less than memory does; keep what it does not record.
        func note(id: String, page: Int?, cfi: String?, quote: String, section: String?, body: String) -> NoteEntry {
            guard var kept = oldNotes[id] else {
                return NoteEntry(id: id, page: page, cfi: cfi, quote: quote, section: section, body: body)
            }
            if kept.body != body { kept.updated = ISO8601DateFormatter().string(from: Date()) }
            kept.page = page
            kept.cfi = cfi
            kept.quote = quote
            kept.section = section
            kept.body = body
            return kept
        }
        for file in files {
            let section = ChapterFiles.number(in: file.name).map { "Chapter \($0)" }
            for block in VaultNoteFile.blocks(file.text) {
                ids.insert(block.id)
                let page = block.link.pageNumber
                let cfi = PassageIdentity.cfi(block.link.location)
                let hasBody = !block.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let color = block.color {
                    let old = oldHighlights[block.id]
                    let noteID = old?.noteID ?? (hasBody ? block.id : nil)
                    var linked: String?
                    if let noteID, hasBody {
                        notes.append(note(id: noteID, page: page, cfi: cfi, quote: block.quote, section: section, body: block.body))
                        ids.insert(noteID)
                        linked = noteID
                    } else if let noteID, let typing = oldNotes[noteID], AnnotationEdit.isBlankNote(typing.body) {
                        notes.append(typing)
                        linked = noteID
                    }
                    highlights.append(HighlightEntry(id: block.id, color: color, page: page, cfi: cfi, quote: block.quote, prefix: old?.prefix ?? "", suffix: old?.suffix ?? "", section: section, rects: old?.rects ?? [], noteID: linked))
                } else if hasBody {
                    notes.append(note(id: block.id, page: page, cfi: cfi, quote: block.quote, section: section, body: block.body))
                }
            }
        }
        AnnotationEdit.dropDuplicateNotes(highlights: &highlights, notes: &notes)
        session.package.notes.notes = notes
        session.package.highlights.highlights = highlights
        loadedBlockIDs = ids
    }

    func scheduleFlush(_ session: ReaderSession) {
        needsFlush = true
        flushTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.flushReportingErrors(session)
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func flushReportingErrors(_ session: ReaderSession) {
        do {
            try flush(session)
        } catch {
            session.notice = "Couldn't save to the vault. \(error.localizedDescription)"
        }
    }

    func flush(_ session: ReaderSession) throws {
        guard settings.enabled else { return }
        session.flushNoteBodies()
        // An edit made outside Reader is merged in before anything is written over it.
        if notesChangedOnDisk() { reload(into: session, mergePending: true) }
        flushTimer?.invalidate()
        flushTimer = nil
        holdOwnWrite()
        try writeNotes(session)
        try writeWords(session)
        settings.view = session.package.state
        settings.claudeSessionID = session.claudeSessionID
        settings.showConceptMarkers = session.showConceptMarkers
        session.persistVaultMarks()
        try settings.save(bookFolder: location.bookFolder, fs: fs)
        needsFlush = false
        needsRelocation = false
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

    private func writeNotes(_ session: ReaderSession) throws {
        let directory = notesDirectory
        try fs.createDirectory(directory)
        let grouped = annotationsByFile(session)
        let explicitlyDeleted = session.deletedAnnotationIDs
        for name in Set(grouped.keys).union(noteFileNames()) {
            let path = Paths.join(directory, name)
            let text = fs.exists(path) ? try fs.readString(path) : ""
            let items = grouped[name] ?? []
            let remove = removedIDs(in: text, keeping: items, explicitlyDeleted: explicitlyDeleted)
            if items.isEmpty, remove.isEmpty { continue }
            let written = VaultAnnotationSync.render(existing: text, bookPath: session.bookURL.path, annotations: items, removeIDs: remove, updatingLocations: needsRelocation)
            try writeIfChanged(path, written)
            loadedBlockIDs.subtract(remove)
            for item in items { loadedBlockIDs.insert(item.id) }
        }
        session.deletedAnnotationIDs.subtract(explicitlyDeleted)
    }

    private func writeWords(_ session: ReaderSession) throws {
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
            let rawDefinition = word.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            let meaningSource = (rawDefinition.isEmpty || rawDefinition == "No dictionary entry.")
                ? (word.explanation ?? "")
                : rawDefinition
            let entry = VocabEntry(
                id: word.id,
                word: word.word,
                chapter: lookup?.section.flatMap { ChapterFiles.number(in: $0) },
                page: lookup?.page,
                meaning: VocabularyFile.shortMeaning(meaningSource),
                bookContext: word.lookups.first?.sentence ?? word.lookups.first?.quote ?? word.word,
                plainLanguage: word.explanation,
                example: nil,
                added: added,
                readerOwned: true
            )
            text = VocabularyFile.upsert(text, title: title, entry: entry)
            loadedWords[word.id] = word.word
        }
        if text.isEmpty, !fs.exists(path) { return }
        try fs.createDirectory(Paths.parent(path))
        try writeIfChanged(path, text)
    }

    private func writeIfChanged(_ path: String, _ text: String) throws {
        // An open Markdown file inside the vault is never a place for Reader's blocks.
        if let openBook, URL(fileURLWithPath: path).resolvingSymlinksInPath() == openBook.resolvingSymlinksInPath() { return }
        if (try? fs.readString(path)) != text { try fs.writeString(path, text) }
        known[path] = text
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
