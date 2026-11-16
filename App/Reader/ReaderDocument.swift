import AppKit
import ReaderCore

final class ReaderDocument: NSDocument {
    var session: ReaderSession?
    private var bookData = Data()

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        let opened = try Self.resolveBook(url)
        bookData = opened.data
        fileURL = opened.url
        fileType = opened.kind == .epub ? "org.idpf.epub-container" : "com.adobe.pdf"
        let fs = LocalFileSystem()
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
        session.onDirty = { [weak self] in
            self?.updateChangeCount(.changeDone)
            self?.refreshSubtitle()
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
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        do {
            try session?.persistSidecar()
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

    func refreshSubtitle() {
        guard let session, let window = windowControllers.first?.window else { return }
        let edited = isDocumentEdited ? " — Edited" : ""
        if session.isPDF {
            window.subtitle = "Page \(session.page) of \(max(session.pageCount, 1))\(edited)"
        } else {
            let place = session.sectionTitle.isEmpty ? "EPUB" : session.sectionTitle
            window.subtitle = "\(place)\(edited)"
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
