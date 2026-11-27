import AppKit
import ReaderCore

final class ReaderDocument: NSDocument {
    var session: ReaderSession?
    private var vault: VaultCoordinator?
    private var bookData = Data()
    private static var pendingVaultNotice: String?
    /// Set while a book is being opened into an existing pane, so it does not also get its own window.
    static var openingIntoPane = false
    private static var queuedLinks: [String: ReaderLink] = [:]

    /// Holds a deep link until `read` builds the session, so the first layout can land on it.
    static func queue(_ link: ReaderLink) {
        queuedLinks[key(link.path)] = link
    }

    static func takeQueuedLink(for path: String) -> ReaderLink? {
        queuedLinks.removeValue(forKey: key(path))
    }

    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

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
            if let link = Self.takeQueuedLink(for: opened.url.path) {
                session.pendingReaderLink = link
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
        if let link = Self.takeQueuedLink(for: opened.url.path) {
            session.pendingReaderLink = link
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
        if Self.openingIntoPane { return }
        guard let session else { return }
        session.undoManager = undoManager
        let controller = ReaderWindowController(session: session)
        addWindowController(controller)
        session.undoManager = undoManager
        controller.attachHostDocument()
        refreshSubtitle()
        Task { @MainActor in
            SyncController.shared.register(session)
            SyncController.shared.applyOpeningPosition(to: session)
        }
    }

    override func close() {
        if let session {
            Task { @MainActor in
                SyncController.shared.unregister(session)
            }
        }
        super.close()
    }

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

    override func save(_ sender: Any?) {
        // Avoid NSDocument's performActivityWithSynchronousWaiting path.
        // If an earlier activity is stuck (historically a modal "Save to Vault"
        // alert during windowDidBecomeKey), that wait freezes the main thread
        // at 0% CPU with no recovery.
        for controller in windowControllers {
            controller.window?.endEditing(for: nil)
        }
        persistSidecarOrVault(clearEdited: true) { [weak self] error in
            if let error {
                self?.presentError(error)
            }
        }
    }

    func reveal(_ link: ReaderLink) {
        _ = Self.takeQueuedLink(for: link.path)
        guard let session else {
            Self.queue(link)
            return
        }
        session.pendingReaderLink = link
        let controllers = windowControllers.compactMap { $0 as? ReaderWindowController }
        if controllers.isEmpty { return }
        for controller in controllers {
            controller.applyPendingLink()
        }
    }

    /// Autosave writes the sidecar only. The book file is never replaced.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        // May be invoked off the main thread during autosave. AppKit work and
        // the completion handler must run on the main thread. If we are already
        // on the main thread, complete synchronously — dispatching async here
        // deadlocks performActivityWithSynchronousWaiting.
        let clearEdited = saveOperation != .saveToOperation
        let finish: (Error?) -> Void = { error in
            completionHandler(error)
        }
        if Thread.isMainThread {
            persistSidecarOrVault(clearEdited: clearEdited, completion: finish)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.persistSidecarOrVault(clearEdited: clearEdited, completion: finish) ?? finish(nil)
            }
        }
    }

    private func persistSidecarOrVault(clearEdited: Bool, completion: @escaping (Error?) -> Void) {
        if session?.usesVault == true {
            session?.persistVaultMarks()
            session?.onVaultSave?()
            if clearEdited {
                updateChangeCount(.changeCleared)
            }
            completion(nil)
            return
        }
        do {
            try session?.persistSidecar()
            // This path replaces NSDocument's save, which is what normally
            // clears the edited flag. Without this, " — Edited" stays after ⌘S.
            if clearEdited {
                updateChangeCount(.changeCleared)
            }
            completion(nil)
        } catch {
            completion(error)
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

    /// Writes the sidecar, then closes the document. Used when the last pane of this book goes away.
    func saveForPaneClose() {
        let url = fileURL ?? session?.bookURL
        let finish: (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            if error != nil { try? self.session?.persistSidecar() }
            if !self.isShownInAWindow() { self.close() }
        }
        guard let url else {
            finish(nil)
            return
        }
        save(to: url, ofType: fileType ?? "com.adobe.pdf", for: .autosaveInPlaceOperation, completionHandler: finish)
    }

    private func isShownInAWindow() -> Bool {
        guard let session else { return !windowControllers.isEmpty }
        for case let reader as ReaderDocument in NSDocumentController.shared.documents {
            for controller in reader.windowControllers {
                if (controller as? ReaderWindowController)?.shows(session) == true { return true }
            }
        }
        return false
    }

    /// Page or section text only. AppKit appends " — Edited" while the document
    /// is dirty and removes it when the change count is cleared.
    func refreshSubtitle() {
        guard let session else { return }
        let active = windowControllers.compactMap { controller -> NSWindow? in
            guard let reader = controller as? ReaderWindowController, reader.session === session else { return nil }
            return controller.window
        }
        let windows = active.isEmpty ? windowControllers.compactMap(\.window) : active
        for window in windows {
            if session.isPDF {
                window.subtitle = "Page \(session.page) of \(max(session.pageCount, 1))"
            } else {
                window.subtitle = session.sectionTitle.isEmpty ? "EPUB" : session.sectionTitle
            }
            window.title = session.bookURL.deletingPathExtension().lastPathComponent
        }
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
