import Foundation

public enum Placement: String, Codable, Equatable, Sendable {
    case sibling
    case applicationSupport
}

public struct LibraryEntry: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var pdfID: String?
    public var epubID: String?
    public var title: String
    public var bookPath: String
    public var sidecarPath: String
    public var placement: Placement
    public var updated: String

    public init(fingerprint: String, pdfID: String?, epubID: String?, title: String, bookPath: String, sidecarPath: String, placement: Placement, updated: String) {
        self.fingerprint = fingerprint
        self.pdfID = pdfID
        self.epubID = epubID
        self.title = title
        self.bookPath = bookPath
        self.sidecarPath = sidecarPath
        self.placement = placement
        self.updated = updated
    }
}

public struct LibraryIndex: Codable, Equatable, Sendable {
    public var documents: [LibraryEntry]

    public init(documents: [LibraryEntry] = []) {
        self.documents = documents
    }

    public static func load(from path: String, fs: FileSystem) -> LibraryIndex {
        guard fs.exists(path), let data = try? fs.read(path),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else {
            return LibraryIndex()
        }
        return index
    }

    public func save(to path: String, fs: FileSystem) throws {
        try fs.createDirectory(Paths.parent(path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.write(path, encoder.encode(self))
    }
}

public struct SidecarPackage: Equatable, Sendable {
    public var notes: NotesDocument
    public var words: WordsDocument
    public var highlights: HighlightsDocument
    public var marks: MarksDocument
    public var state: ViewState

    public init(notes: NotesDocument, words: WordsDocument, highlights: HighlightsDocument, marks: MarksDocument, state: ViewState) {
        self.notes = notes
        self.words = words
        self.highlights = highlights
        self.marks = marks
        self.state = state
    }

    public static func empty(identity: FrontMatter, state: ViewState = .fresh) -> SidecarPackage {
        SidecarPackage(
            notes: NotesDocument(frontMatter: identity.withKind("notes"), notes: []),
            words: WordsDocument(frontMatter: identity.withKind("words"), words: []),
            highlights: HighlightsDocument(frontMatter: identity.withKind("highlights"), highlights: []),
            marks: MarksDocument(frontMatter: identity.withKind("marks"), marks: []),
            state: state
        )
    }

    public static func read(from directory: String, fs: FileSystem) throws -> SidecarPackage {
        func text(_ name: String) -> String? {
            let path = Paths.join(directory, name)
            guard fs.exists(path) else { return nil }
            return try? fs.readString(path)
        }
        let notesText = text("notes.md") ?? ""
        let notes = notesText.isEmpty
            ? NotesDocument(frontMatter: FrontMatter(kind: "notes", document: "", fingerprint: ""), notes: [])
            : NotesDocument.parse(notesText)
        let words = text("words.md").map(WordsDocument.parse)
            ?? WordsDocument(frontMatter: notes.frontMatter.withKind("words"), words: [])
        let highlights = text("highlights.md").map(HighlightsDocument.parse)
            ?? HighlightsDocument(frontMatter: notes.frontMatter.withKind("highlights"), highlights: [])
        let marks = text("marks.md").map { MarksDocument.parse($0, forcedScope: .local) }
            ?? MarksDocument(frontMatter: notes.frontMatter.withKind("marks"), marks: [])
        let state: ViewState
        if let data = try? fs.read(Paths.join(directory, "state.json")),
           let decoded = try? JSONDecoder().decode(ViewState.self, from: data) {
            state = decoded
        } else {
            state = .fresh
        }
        return SidecarPackage(notes: notes, words: words, highlights: highlights, marks: marks, state: state)
    }

    public func write(to directory: String, fs: FileSystem) throws {
        try fs.createDirectory(directory)
        try fs.writeString(Paths.join(directory, "notes.md"), notes.render())
        try fs.writeString(Paths.join(directory, "words.md"), words.render())
        try fs.writeString(Paths.join(directory, "highlights.md"), highlights.render())
        try fs.writeString(Paths.join(directory, "marks.md"), marks.render())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.write(Paths.join(directory, "state.json"), try encoder.encode(state))
    }

    public func refreshingFingerprint(_ fingerprint: String) -> SidecarPackage {
        var copy = self
        copy.notes.frontMatter.fingerprint = fingerprint
        copy.words.frontMatter.fingerprint = fingerprint
        copy.highlights.frontMatter.fingerprint = fingerprint
        copy.marks.frontMatter.fingerprint = fingerprint
        return copy
    }
}

public struct OpenResult: Equatable, Sendable {
    public var package: SidecarPackage
    public var directory: String
    public var placement: Placement
    public var notice: String?
    public var offerMoveTo: String?
    public var needsReanchor: Bool
    public var renamedFrom: String?
    /// False when this open created the sidecar, or the package had no `state.json`.
    /// The window uses that to fit the page width instead of restoring a zoom.
    public var hasSavedViewState: Bool

    public init(package: SidecarPackage, directory: String, placement: Placement, notice: String? = nil, offerMoveTo: String? = nil, needsReanchor: Bool = false, renamedFrom: String? = nil, hasSavedViewState: Bool = false) {
        self.package = package
        self.directory = directory
        self.placement = placement
        self.notice = notice
        self.offerMoveTo = offerMoveTo
        self.needsReanchor = needsReanchor
        self.renamedFrom = renamedFrom
        self.hasSavedViewState = hasSavedViewState
    }
}

public enum BookKind: String, Equatable, Sendable {
    case pdf
    case epub

    public static func from(path: String) -> BookKind? {
        let lower = path.lowercased()
        if lower.hasSuffix(".pdf") { return .pdf }
        if lower.hasSuffix(".epub") { return .epub }
        return nil
    }
}

enum IdentityMatch {
    case exact
    case stableID
    case different
}

public enum PDFIdentity {
    /// Best-effort scan of a PDF trailer `/ID [<hex> <hex>]`. The trailer is
    /// usually uncompressed even when page streams are not. Returns nil when
    /// the file has no readable ID (PDFKit on the Mac is the fallback).
    public static func scan(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        guard let range = text.range(of: "/ID", options: .backwards) else { return nil }
        let tail = text[range.upperBound...]
        guard let open = tail.firstIndex(of: "<"), let close = tail[tail.index(after: open)...].firstIndex(of: ">") else {
            return nil
        }
        let hex = tail[tail.index(after: open)..<close]
            .filter { $0.isHexDigit }
        let value = String(hex).lowercased()
        return value.isEmpty ? nil : value
    }
}

public enum SidecarStore {
    public static func open(
        bookPath: String,
        bookData: Data,
        title: String?,
        index: inout LibraryIndex,
        applicationSupport: String,
        fs: FileSystem,
        now: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> OpenResult {
        let fingerprint = SHA256.fingerprint(bookData)
        let filename = Paths.name(bookPath)
        let kind = BookKind.from(path: bookPath)
        let pdfID = kind == .pdf ? PDFIdentity.scan(bookData) : nil
        let epubID: String? = kind == .epub ? (try? EPUBBook(data: bookData).identifier) : nil
        let parent = Paths.parent(bookPath)
        let sibling = Paths.join(parent, Paths.stem(bookPath) + ".reader")
        let resolvedTitle = title ?? Paths.stem(bookPath)

        var renamedFrom: String?
        var notice: String?
        if !fs.exists(sibling), let names = try? fs.list(parent) {
            for name in names where name.hasSuffix(".reader") {
                let candidate = Paths.join(parent, name)
                guard fs.isDirectory(candidate), let stored = storedIdentity(candidate, fs: fs) else { continue }
                if stored.fingerprint == fingerprint {
                    try fs.move(candidate, sibling)
                    renamedFrom = candidate
                    notice = "Renamed \(name) to \(Paths.name(sibling)) so it stays with the book."
                    break
                }
            }
        }

        if fs.isDirectory(sibling) {
            let hadViewState = fs.exists(Paths.join(sibling, "state.json"))
            var package = try SidecarPackage.read(from: sibling, fs: fs)
            let stored = storedIdentity(sibling, fs: fs)
            let match = matchIdentity(
                fingerprint: fingerprint, pdfID: pdfID, epubID: epubID,
                otherFingerprint: stored?.fingerprint ?? package.notes.frontMatter.fingerprint,
                otherPDF: stored?.pdfID ?? package.notes.frontMatter.pdfID,
                otherEPUB: stored?.epubID ?? package.notes.frontMatter.epubID
            )
            var needsReanchor = false
            switch match {
            case .exact:
                break
            case .stableID:
                package = package.refreshingFingerprint(fingerprint)
                package.notes.frontMatter.pdfID = pdfID ?? package.notes.frontMatter.pdfID
                package.words.frontMatter = package.notes.frontMatter.withKind("words")
                package.highlights.frontMatter = package.notes.frontMatter.withKind("highlights")
                package.marks.frontMatter = package.notes.frontMatter.withKind("marks")
                try package.write(to: sibling, fs: fs)
                notice = [notice, "Updated the content fingerprint after a small edit to the book."].compactMap { $0 }.joined(separator: " ")
            case .different:
                needsReanchor = true
                notice = [notice, "This file doesn't match the notes saved beside it. Reader can re-find each entry by its quoted text."].compactMap { $0 }.joined(separator: " ")
            }
            let result = OpenResult(package: package, directory: sibling, placement: .sibling, notice: notice, needsReanchor: needsReanchor, renamedFrom: renamedFrom, hasSavedViewState: hadViewState)
            record(result, fingerprint: fingerprint, pdfID: pdfID, epubID: epubID, title: resolvedTitle, bookPath: bookPath, index: &index, now: now)
            return result
        }

        if let existing = index.documents.first(where: { entry in
            guard fs.isDirectory(entry.sidecarPath) else { return false }
            if entry.fingerprint == fingerprint { return true }
            if let pdfID, entry.pdfID == pdfID { return true }
            if let epubID, entry.epubID == epubID { return true }
            return false
        }), Paths.normalize(existing.sidecarPath) != Paths.normalize(sibling) {
            let hadViewState = fs.exists(Paths.join(existing.sidecarPath, "state.json"))
            var package = try SidecarPackage.read(from: existing.sidecarPath, fs: fs)
            if package.notes.frontMatter.fingerprint != fingerprint {
                package = package.refreshingFingerprint(fingerprint)
                try package.write(to: existing.sidecarPath, fs: fs)
            }
            let result = OpenResult(
                package: package,
                directory: existing.sidecarPath,
                placement: existing.placement,
                notice: "This book moved. Its notes are still in the previous folder.",
                offerMoveTo: sibling,
                renamedFrom: renamedFrom,
                hasSavedViewState: hadViewState
            )
            record(result, fingerprint: fingerprint, pdfID: pdfID, epubID: epubID, title: resolvedTitle, bookPath: bookPath, index: &index, now: now)
            return result
        }

        let identity = FrontMatter(kind: "notes", document: filename, fingerprint: fingerprint, pdfID: pdfID, epubID: epubID)
        let package = SidecarPackage.empty(identity: identity)
        let created = try create(package, sibling: sibling, digest: SHA256.hex(bookData), applicationSupport: applicationSupport, fs: fs)
        let result = OpenResult(
            package: package,
            directory: created.directory,
            placement: created.placement,
            notice: created.notice,
            renamedFrom: renamedFrom,
            hasSavedViewState: false
        )
        record(result, fingerprint: fingerprint, pdfID: pdfID, epubID: epubID, title: resolvedTitle, bookPath: bookPath, index: &index, now: now)
        return result
    }

    public static func acceptMove(from: String, to: String, bookPath: String, fingerprint: String, index: inout LibraryIndex, fs: FileSystem) throws {
        if fs.exists(to) {
            throw ReaderFailure("A notes package is already next to the book.")
        }
        try fs.createDirectory(Paths.parent(to))
        try fs.move(from, to)
        if let indexPosition = index.documents.firstIndex(where: { $0.fingerprint == fingerprint }) {
            index.documents[indexPosition].sidecarPath = to
            index.documents[indexPosition].placement = .sibling
            index.documents[indexPosition].bookPath = bookPath
        }
    }

    private static func create(_ package: SidecarPackage, sibling: String, digest: String, applicationSupport: String, fs: FileSystem) throws -> (directory: String, placement: Placement, notice: String?) {
        let parent = Paths.parent(sibling)
        do {
            if !fs.isWritable(parent) {
                throw ReaderFailure("The folder can't be written.")
            }
            try package.write(to: sibling, fs: fs)
            return (sibling, .sibling, nil)
        } catch {
            let directory = Paths.join(Paths.join(applicationSupport, "Sidecars"), digest + ".reader")
            try package.write(to: directory, fs: fs)
            return (directory, .applicationSupport, "Couldn't create a notes package next to the book, so Reader is using \(directory).")
        }
    }

    private static func storedIdentity(_ directory: String, fs: FileSystem) -> (fingerprint: String, pdfID: String?, epubID: String?)? {
        for name in ["notes.md", "words.md", "highlights.md", "marks.md"] {
            let path = Paths.join(directory, name)
            guard fs.exists(path), let text = try? fs.readString(path) else { continue }
            let (matter, _, _) = MarkdownText.splitFrontMatter(text)
            if let matter, !matter.fingerprint.isEmpty {
                return (matter.fingerprint, matter.pdfID, matter.epubID)
            }
        }
        return nil
    }

    private static func matchIdentity(fingerprint: String, pdfID: String?, epubID: String?, otherFingerprint: String, otherPDF: String?, otherEPUB: String?) -> IdentityMatch {
        if !otherFingerprint.isEmpty, fingerprint == otherFingerprint { return .exact }
        if let pdfID, let otherPDF, !pdfID.isEmpty, pdfID == otherPDF { return .stableID }
        if let epubID, let otherEPUB, !epubID.isEmpty, epubID == otherEPUB { return .stableID }
        return .different
    }

    private static func record(_ result: OpenResult, fingerprint: String, pdfID: String?, epubID: String?, title: String, bookPath: String, index: inout LibraryIndex, now: String) {
        index.documents.removeAll { entry in
            entry.fingerprint == fingerprint
                || (pdfID != nil && entry.pdfID == pdfID)
                || (epubID != nil && entry.epubID == epubID)
                || entry.bookPath == bookPath
        }
        index.documents.append(LibraryEntry(
            fingerprint: fingerprint,
            pdfID: pdfID,
            epubID: epubID,
            title: title,
            bookPath: bookPath,
            sidecarPath: result.directory,
            placement: result.placement,
            updated: now
        ))
    }
}
