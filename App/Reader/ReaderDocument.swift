import AppKit
import ReaderCore

final class ReaderDocument: NSDocument {
    var session: ReaderSession?
    private var vault: VaultCoordinator?
    private var bookData = Data()
    private static var pendingVaultNotice: String?

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        let opened = try Self.resolveBook(url)
        bookData = opened.data
        fileURL = opened.url
        fileType = opened.kind == .epub ? "org.idpf.epub-container" : "com.adobe.pdf"
        let fs = LocalFileSystem()
        let library = LibraryIndex.load(from: AppPaths.indexFile, fs: fs)
        let linked = library.documents.first { $0.bookPath == opened.url.path }?.vaultBookFolder
        let unlinked = UserDefaults.standard.stringArray(forKey: "reader.unlinkedVaults")?.contains(opened.url.path) == true
        let openedVault: (coordinator: VaultCoordinator?, notice: String?) = unlinked ? (nil, nil) : VaultCoordinator.make(bookPath: opened.url.path, linkedFolder: linked)
        if let notice = openedVault.notice {
            // Applied once the session exists on the sidecar path below.
            Self.pendingVaultNotice = notice
        }
        if let coordinator = openedVault.coordinator {
            Self.pendingVaultNotice = nil
            let hasState = fs.exists(Paths.join(coordinator.location.bookFolder, ".reader-state.json"))
            let identity = FrontMatter(kind: "notes", document: opened.url.lastPathComponent, fingerprint: SHA256.fingerprint(opened.data))
            let result = OpenResult(package: SidecarPackage.empty(identity: identity), directory: coordinator.location.bookFolder, placement: .sibling, hasSavedViewState: hasState)
            let session = ReaderSession(bookURL: opened.url, bookData: opened.data, open: result)
            if hasState {
                session.package.state = VaultBookSettings.load(bookFolder: coordinator.location.bookFolder, fs: fs).view
                session.fitMode = session.package.state.fitMode
                session.zoom = session.package.state.zoom
                session.page = max(session.package.state.page, 1)
            }
            coordinator.attach(session)
            let storedMarks = BookMarks.load(applicationSupport: AppPaths.support, fingerprint: identity.fingerprint, fs: fs)
            if !storedMarks.isEmpty {
                session.package.marks.marks = storedMarks
            }
            if let pending = MarkOpenQueue.take(path: opened.url.path) {
                session.pendingMarkReveal = pending
                if let page = pending.page {
                    session.page = max(page, 1)
                    session.package.state.page = session.page
                }
                if let scroll = pending.scrollY { session.package.state.scrollY = scroll }
            }
            var index = LibraryIndex.load(from: AppPaths.indexFile, fs: fs)
            SidecarStore.noteVaultBook(
                bookPath: opened.url.path,
                directory: coordinator.location.bookFolder,
                title: opened.url.deletingPathExtension().lastPathComponent,
                fingerprint: identity.fingerprint,
                index: &index,
                now: ISO8601DateFormatter().string(from: Date())
            )
            try? index.save(to: AppPaths.indexFile, fs: fs)
            session.onPageChange = { [weak self] in self?.refreshSubtitle() }
            self.vault = coordinator
            self.session = session
            DispatchQueue.main.async { [weak self] in self?.refreshSubtitle() }
            return
        }
        var index = LibraryIndex.load(from: AppPaths.indexFile, fs: fs)
        let result = try SidecarStore.open(
            bookPath: opened.url.path,
            bookData: opened.data,
            title: opened.url.deletingPathExtension().lastPathComponent,
            index: &index,
            applicationSupport: AppPaths.support,
            fs: fs
        )
        try index.save(to: AppPaths.indexFile, fs: fs)
        let session = ReaderSession(bookURL: opened.url, bookData: opened.data, open: result)
        if let pending = MarkOpenQueue.take(path: opened.url.path) {
            session.pendingMarkReveal = pending
            if let page = pending.page {
                session.page = max(page, 1)
                session.package.state.page = session.page
            }
            if let scroll = pending.scrollY { session.package.state.scrollY = scroll }
        }
        if let notice = Self.pendingVaultNotice {
            session.notice = notice
            Self.pendingVaultNotice = nil
        }
        session.onDirty = { [weak self] in
            // Set the page subtitle first, then mark edited. AppKit appends " — Edited"
            // itself; including it here shows the suffix twice.
            self?.refreshSubtitle()
            self?.updateChangeCount(.changeDone)
        }
        session.onPageChange = { [weak self] in
            self?.refreshSubtitle()
        }
        self.session = session
        DispatchQueue.main.async { [weak self] in self?.refreshSubtitle() }
    }

    override func makeWindowControllers() {
        guard let session else { return }
        session.undoManager = undoManager
        let controller = ReaderWindowController(session: session)
        addWindowController(controller)
        session.undoManager = undoManager
        refreshSubtitle()
    }

    /// Autosave writes the sidecar only. The book file is never replaced.
    static func openMark(path: String, position: ReadingPosition) {
        MarkOpenQueue.store(path: path, position: position)
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { document, _, _ in
            (document as? ReaderDocument)?.revealMark(position)
        }
    }

    func revealMark(_ position: ReadingPosition) {
        session?.pendingMarkReveal = position
        if let page = position.page {
            session?.page = max(page, 1)
            session?.package.state.page = session?.page ?? 1
        }
        if let scroll = position.scrollY {
            session?.package.state.scrollY = scroll
        }
        if let controller = windowControllers.first as? ReaderWindowController {
            controller.reveal(position)
        }
    }

    func reveal(_ link: ReaderLink) {
        session?.pendingReaderLink = link
        session?.onAnnotationsChanged?()
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if session?.usesVault == true {
            session?.persistVaultMarks()
            session?.onVaultFlush?()
            if saveOperation != .saveToOperation {
                updateChangeCount(.changeCleared)
            }
            completionHandler(nil)
            return
        }
        do {
            try session?.persistSidecar()
            // This override replaces NSDocument's save, which is what normally
            // clears the edited flag. Without this, " — Edited" stays after ⌘S.
            if saveOperation != .saveToOperation {
                updateChangeCount(.changeCleared)
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    override func write(to url: URL, ofType typeName: String) throws {
        try session?.persistSidecar()
    }

    override func data(ofType typeName: String) throws -> Data {
        bookData
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        refreshSubtitle()
    }

    /// Page or section text only. AppKit appends " — Edited" while the document
    /// is dirty and removes it when the change count is cleared.
    func refreshSubtitle() {
        guard let session, let window = windowControllers.first?.window else { return }
        if session.isPDF {
            window.subtitle = "Page \(session.page) of \(max(session.pageCount, 1))"
        } else {
            window.subtitle = session.sectionTitle.isEmpty ? "EPUB" : session.sectionTitle
        }
        window.title = session.bookURL.deletingPathExtension().lastPathComponent
    }

    private static func resolveBook(_ url: URL) throws -> (url: URL, data: Data, kind: BookKind) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue || url.pathExtension == "reader" {
            let siblingPDF = url.deletingPathExtension().appendingPathExtension("pdf")
            let siblingEPUB = url.deletingPathExtension().appendingPathExtension("epub")
            if FileManager.default.fileExists(atPath: siblingPDF.path) {
                return (siblingPDF, try Data(contentsOf: siblingPDF), .pdf)
            }
            if FileManager.default.fileExists(atPath: siblingEPUB.path) {
                return (siblingEPUB, try Data(contentsOf: siblingEPUB), .epub)
            }
            let index = LibraryIndex.load(from: AppPaths.indexFile, fs: LocalFileSystem())
            if let entry = index.documents.first(where: { $0.sidecarPath == url.path }),
               FileManager.default.fileExists(atPath: entry.bookPath) {
                let book = URL(fileURLWithPath: entry.bookPath)
                let kind = BookKind.from(path: book.path) ?? .pdf
                return (book, try Data(contentsOf: book), kind)
            }
            throw ReaderFailure("This notes package has no book next to it.")
        }
        let data = try Data(contentsOf: url)
        let kind = BookKind.from(path: url.path) ?? .pdf
        return (url, data, kind)
    }
}
