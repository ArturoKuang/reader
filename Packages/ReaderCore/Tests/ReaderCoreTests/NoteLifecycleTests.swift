import Foundation
import ReaderCore
import XCTest

/// The note lifecycle in the core package: editing, anchoring, persistence, and vault merging.
/// Everything here runs without a window, so each test is a regression lock for one UI bug.
final class NoteLifecycleTests: XCTestCase {
    private func emptyPackage(_ document: String = "Book.pdf") -> SidecarPackage {
        SidecarPackage.empty(identity: FrontMatter(kind: "notes", document: document, fingerprint: "sha256:x"))
    }

    // MARK: Empty body dismissal (BUG-01)

    func testEmptyBodyAndPlaceholderPruningKeepsHighlight() {
        for blank in ["", "   \n\t ", "Write a note…", "Add Note"] {
            var package = emptyPackage()
            let anchor = AnnotationAnchor(text: "hard to vary", page: 4, section: "Chapter 4", rects: [[10, 20, 80, 32]])
            addLegacyNote(toSelection: anchor, color: 3, highlightID: "h1", noteID: "n1", now: "t", package: &package)
            AnnotationEdit.updateNoteBody(id: "n1", body: "a real thought", now: "t2", package: &package)
            XCTAssertEqual(package.notes.notes.map(\.body), ["a real thought"])
            AnnotationEdit.updateNoteBody(id: "n1", body: blank, now: "t3", package: &package)
            XCTAssertTrue(package.notes.notes.isEmpty, "blank body \(blank.debugDescription) must drop the note")
            let highlight = package.highlights.highlights.first
            XCTAssertNil(highlight?.noteID)
            XCTAssertEqual(highlight?.color, 3)
            XCTAssertEqual(highlight?.rects, [[10, 20, 80, 32]])
        }
    }

    func testClosingAFreshNoteWithoutTypingLeavesOnlyTheHighlight() {
        var package = emptyPackage()
        let anchor = AnnotationAnchor(text: "hard to vary", page: 4, rects: [[1, 2, 3, 4]])
        addLegacyNote(toSelection: anchor, color: 2, highlightID: "h1", noteID: "n1", now: "t", package: &package)
        XCTAssertEqual(package.notes.notes.map(\.body), [""])
        var buffer = NoteEditBuffer()
        let begun = buffer.begin(id: "h1", newNoteID: "n-unused", package: &package, now: "t")
        let token = try! XCTUnwrap(begun?.token)
        let result = buffer.end(token, package: &package, now: "t2")
        XCTAssertEqual(result?.changed, true)
        XCTAssertNil(result?.undo, "nothing was typed, so there is nothing to undo")
        XCTAssertTrue(package.notes.notes.isEmpty)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h1"])
        XCTAssertNil(package.highlights.highlights[0].noteID)
        XCTAssertFalse(AnnotationIndex.items(highlights: package.highlights.highlights, notes: package.notes.notes)[0].hasNote)
    }

    func testClearingAnExistingNoteDropsItAndUndoRestoresTheBody() {
        var package = emptyPackage()
        let anchor = AnnotationAnchor(text: "hard to vary", page: 4, rects: [[1, 2, 3, 4]])
        addLegacyNote(toSelection: anchor, color: 2, highlightID: "h1", noteID: "n1", now: "t", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "keep me", now: "t", package: &package)
        var buffer = NoteEditBuffer()
        let token = try! XCTUnwrap(buffer.begin(id: "h1", newNoteID: "n-new", package: &package, now: "t")?.token)
        XCTAssertTrue(buffer.queue(token, body: "  "))
        let result = buffer.end(token, package: &package, now: "t2")
        XCTAssertTrue(package.notes.notes.isEmpty)
        XCTAssertEqual(package.highlights.highlights.count, 1)
        let undo = try! XCTUnwrap(result?.undo)
        let redo = undo.restore(into: &package)
        XCTAssertEqual(package.notes.notes.map(\.body), ["keep me"])
        XCTAssertEqual(package.highlights.highlights[0].noteID, "n1")
        redo?.restore(into: &package)
        XCTAssertTrue(package.notes.notes.isEmpty, "redo clears the note again")
        undo.restore(into: &package)
        XCTAssertEqual(package.notes.notes.map(\.body), ["keep me"], "undo, redo, undo is stable")
    }

    func testOnlyOneEditorOwnsAnAnnotationAndFirstTypingCreatesTheNoteOnce() {
        var package = emptyPackage()
        _ = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "plain", page: 1, rects: [[0, 0, 5, 5]]), color: 1, id: "h1", package: &package)
        var buffer = NoteEditBuffer()
        let first = try! XCTUnwrap(buffer.begin(id: "h1", newNoteID: "n1", package: &package, now: "t")?.token)
        let second = buffer.begin(id: "h1", newNoteID: "n2", package: &package, now: "t")
        XCTAssertEqual(second?.superseded.map(\.token), [first])
        XCTAssertFalse(buffer.queue(first, body: "stale editor"))
        let token = try! XCTUnwrap(second?.token)
        XCTAssertTrue(buffer.queue(token, body: "typed"))
        XCTAssertTrue(buffer.flush(package: &package, now: "t2"))
        // A new note on a highlight takes the highlight id, whatever the editor proposed.
        XCTAssertEqual(package.notes.notes.map(\.id), ["h1"])
        XCTAssertEqual(package.highlights.highlights[0].noteID, "h1")
        XCTAssertTrue(buffer.queue(token, body: "typed more"))
        _ = buffer.flush(package: &package, now: "t3")
        XCTAssertEqual(package.notes.notes.map(\.body), ["typed more"])
    }

    // MARK: Standalone vs linked notes (BUG-04)

    func testStandaloneLegacyNoteLifecycleAndSnapshotRestore() {
        var package = emptyPackage()
        package.notes.notes = [
            NoteEntry(id: "n-before", page: 1, quote: "earlier", body: "first"),
            NoteEntry(id: "n_old", page: 2, quote: "delta", section: "Chapter 2", created: "t0", body: "legacy body"),
            NoteEntry(id: "n-after", page: 3, quote: "later", body: "last"),
        ]
        let snapshot = package.notes.notes
        var buffer = NoteEditBuffer()
        let token = try! XCTUnwrap(buffer.begin(id: "n_old", newNoteID: "n-unused", package: &package, now: "t")?.token)
        XCTAssertEqual(buffer.annotationID(for: token), "n_old")
        buffer.queue(token, body: "")
        let result = buffer.end(token, package: &package, now: "t1")
        XCTAssertEqual(package.notes.notes.map(\.id), ["n-before", "n-after"])
        let undo = try! XCTUnwrap(result?.undo)
        let redo = undo.restore(into: &package)
        XCTAssertEqual(package.notes.notes, snapshot, "the exact entry returns at its old position")
        redo?.restore(into: &package)
        XCTAssertEqual(package.notes.notes.map(\.id), ["n-before", "n-after"])
        undo.restore(into: &package)
        XCTAssertEqual(package.notes.notes, snapshot)

        let before = package
        AnnotationEdit.recolor(id: "n_old", color: 5, package: &package)
        XCTAssertEqual(package, before, "a standalone note has no color to change")
    }

    func testRecolorSingleAndBatchPreservesLinkedNotes() {
        var package = emptyPackage()
        for (index, text) in ["alpha", "beta", "gamma"].enumerated() {
            let anchor = AnnotationAnchor(text: text, page: 1, rects: [[0, Double(index * 20), 10, Double(index * 20 + 10)]])
            addLegacyNote(toSelection: anchor, color: 1, highlightID: "h\(index + 1)", noteID: "n\(index + 1)", now: "t", package: &package)
            AnnotationEdit.updateNoteBody(id: "n\(index + 1)", body: "note \(index + 1)", now: "t", package: &package)
        }
        package.notes.notes.append(NoteEntry(id: "n-solo", page: 9, quote: "solo", body: "standalone"))
        let notesBefore = package.notes.notes

        // The popover may hold either id; both reach the same highlight.
        AnnotationEdit.recolor(id: "h1", color: 4, package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.color), [4, 1, 1])
        AnnotationEdit.recolor(id: "n2", color: 5, package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.color), [4, 5, 1])
        XCTAssertEqual(package.state.lastHighlightColor, 5)
        AnnotationEdit.recolor(ids: ["h1", "n3", "n-solo"], color: 6, package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.color), [6, 5, 6])
        AnnotationEdit.recolor(id: "h2", color: 99, package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.color), [6, 5, 6], "an invalid color changes nothing")
        XCTAssertEqual(package.highlights.highlights.map(\.noteID), ["n1", "n2", "n3"])
        XCTAssertEqual(package.notes.notes, notesBefore)
    }

    func testRemoveNoteOnlyVsRemoveHighlightAndNoteVsBatch() {
        var package = emptyPackage()
        for (index, text) in ["alpha", "beta", "gamma"].enumerated() {
            let anchor = AnnotationAnchor(text: text, page: 1, rects: [[0, Double(index * 20), 10, Double(index * 20 + 10)]])
            addLegacyNote(toSelection: anchor, color: index + 1, highlightID: "h\(index + 1)", noteID: "n\(index + 1)", now: "t", package: &package)
            AnnotationEdit.updateNoteBody(id: "n\(index + 1)", body: "note \(index + 1)", now: "t", package: &package)
        }
        let highlights = package.highlights.highlights
        let notes = package.notes.notes

        AnnotationEdit.removeNoteOnly(id: "n1", package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h1", "h2", "h3"])
        XCTAssertEqual(package.highlights.highlights.map(\.noteID), [nil, "n2", "n3"])
        XCTAssertEqual(package.notes.notes.map(\.id), ["n2", "n3"])

        AnnotationEdit.restore(highlights: highlights, notes: notes, package: &package)
        AnnotationEdit.removeAnnotation(id: "n2", package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h1", "h3"])
        XCTAssertEqual(package.notes.notes.map(\.id), ["n1", "n3"])

        AnnotationEdit.restore(highlights: highlights, notes: notes, package: &package)
        AnnotationEdit.remove(ids: ["h1", "n3"], package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h2"])
        XCTAssertEqual(package.notes.notes.map(\.id), ["n2"])
        AnnotationEdit.restore(highlights: highlights, notes: notes, package: &package)
        XCTAssertEqual(package.highlights.highlights, highlights)
        XCTAssertEqual(package.notes.notes.map(\.body), ["note 1", "note 2", "note 3"])
        XCTAssertEqual(package.highlights.highlights.map(\.color), [1, 2, 3])
    }

    // MARK: Duplicate quotes (BUG-10)

    func testDuplicateQuotesSamePDFPageDistinctRects() {
        var package = emptyPackage()
        let first = AnnotationAnchor(text: "hard to vary", page: 2, rects: [[72, 600, 160, 612]])
        let second = AnnotationAnchor(text: "hard to vary", page: 2, rects: [[72, 300, 160, 312]])
        XCTAssertEqual(AnnotationEdit.addHighlight(selection: first, color: 1, id: "h1", package: &package)?.id, "h1")
        XCTAssertEqual(AnnotationEdit.addHighlight(selection: second, color: 3, id: "h2", package: &package)?.id, "h2", "a repeat further down the page is a new highlight")
        XCTAssertEqual(package.highlights.highlights.count, 2)
        // The same place again, shifted a little, is the same passage.
        let again = AnnotationAnchor(text: "hard to vary", page: 2, rects: [[73, 601, 161, 613]])
        XCTAssertEqual(AnnotationEdit.addHighlight(selection: again, color: 5, id: "h3", package: &package)?.id, "h1")
        XCTAssertEqual(package.highlights.highlights.count, 2)
        XCTAssertEqual(AnnotationIndex.highlight(matchingQuote: "hard to vary", page: 2, cfi: nil, rects: [[72, 300, 160, 312]], in: package.highlights.highlights)?.id, "h2")
        // Another page never matches.
        XCTAssertNil(AnnotationIndex.highlight(matchingQuote: "hard to vary", page: 3, cfi: nil, rects: [[72, 600, 160, 612]], in: package.highlights.highlights))
        // Reading order puts the upper occurrence first, so each opens its own popover anchor.
        let items = AnnotationIndex.items(highlights: package.highlights.highlights, notes: [])
        XCTAssertEqual(items.map(\.id), ["h1", "h2"])
        XCTAssertEqual(items.map(\.rects), [[[72, 600, 160, 612]], [[72, 300, 160, 312]]])
    }

    func testDuplicateQuotesSameSectionDistinctCFIAndContext() {
        var package = emptyPackage("Book.epub")
        let early = EPUBCFI.make(spineIndex: 1, start: 12, end: 24).value
        let late = EPUBCFI.make(spineIndex: 1, start: 90, end: 102).value
        _ = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "hard to vary", cfi: late, section: "Ch 1", prefix: "is ", suffix: " indeed"), color: 2, id: "h-late", package: &package)
        _ = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "hard to vary", cfi: early, section: "Ch 1", prefix: "a ", suffix: " claim"), color: 1, id: "h-early", package: &package)
        XCTAssertEqual(package.highlights.highlights.count, 2)
        let items = AnnotationIndex.items(highlights: package.highlights.highlights, notes: [])
        XCTAssertEqual(items.map(\.id), ["h-early", "h-late"], "offset order, not creation order")

        // One text node can give two selections the same location; the text around them still differs.
        let shared = EPUBCFI.make(spineIndex: 1, start: 0, end: 3).value
        _ = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "foo", cfi: shared, prefix: "x ", suffix: " bar foo"), color: 1, id: "f1", package: &package)
        let second = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "foo", cfi: shared, prefix: "foo bar ", suffix: " end"), color: 1, id: "f2", package: &package)
        XCTAssertEqual(second?.id, "f2")
        let repeated = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "foo", cfi: shared, prefix: "x ", suffix: " bar foo and more"), color: 1, id: "f3", package: &package)
        XCTAssertEqual(repeated?.id, "f1", "the same context is the same passage")
    }

    func testDuplicateQuotesInOneMarkdownSectionKeepOffsetOrder() {
        var package = emptyPackage("Book.md")
        func anchor(_ start: Int) -> AnnotationAnchor {
            AnnotationAnchor(text: "to be", cfi: "mdloc(s=2,a=intro,o=\(start),e=\(start + 5))", section: "Intro")
        }
        _ = AnnotationEdit.addHighlight(selection: anchor(120), color: 2, id: "h-b", package: &package)
        _ = AnnotationEdit.addHighlight(selection: anchor(10), color: 1, id: "h-a", package: &package)
        XCTAssertEqual(package.highlights.highlights.count, 2, "Markdown offsets already name one occurrence")
        XCTAssertEqual(AnnotationEdit.addHighlight(selection: anchor(120), color: 4, id: "h-c", package: &package)?.id, "h-b")
        XCTAssertEqual(AnnotationIndex.items(highlights: package.highlights.highlights, notes: []).map(\.id), ["h-a", "h-b"])
    }

    // MARK: Persistence (BUG-11)

    func testSidecarPersistenceReopenForPDFEPUBAndMarkdown() throws {
        let cases: [(path: String, anchor: AnnotationAnchor)] = [
            ("/books/Origin.pdf", AnnotationAnchor(text: "natural selection", page: 3, section: "Chapter 3", prefix: "called ", suffix: " works", rects: [[10, 20, 90, 32], [10, 8, 40, 20]])),
            ("/books/Origin.epub", AnnotationAnchor(text: "natural selection", cfi: EPUBCFI.make(spineIndex: 2, start: 5, end: 22).value, section: "Chapter 3", prefix: "called ", suffix: " works")),
            ("/books/Origin.md", AnnotationAnchor(text: "natural selection", cfi: "mdloc(s=2,a=chapter-3,o=5,e=22)", section: "Chapter 3", prefix: "called ", suffix: " works")),
        ]
        let body = "First line\n\n- item one\n- item two\n\nSee [[Natural Selection]]."
        for (path, anchor) in cases {
            let fs = MemoryFileSystem()
            try fs.createDirectory("/books")
            let data = Data("bytes of \(path)".utf8)
            try fs.write(path, data)
            var index = LibraryIndex()
            let opened = try SidecarStore.open(bookPath: path, bookData: data, title: "Origin", index: &index, applicationSupport: "/support", fs: fs, now: "t0")
            XCTAssertEqual(opened.placement, .sibling, path)
            var package = opened.package
            addLegacyNote(toSelection: anchor, color: 4, highlightID: "h1", noteID: "n1", now: "t1", package: &package)
            AnnotationEdit.updateNoteBody(id: "n1", body: body, now: "t2", package: &package)
            _ = AnnotationEdit.addHighlight(selection: AnnotationAnchor(text: "plain highlight", page: anchor.page, cfi: nil, section: "Chapter 3"), color: 2, id: "h2", package: &package)
            addLegacyNote(toSelection: AnnotationAnchor(text: "page note", page: 1), color: 1, highlightID: nil, noteID: "n-solo", now: "t3", package: &package)
            AnnotationEdit.updateNoteBody(id: "n-solo", body: "standalone", now: "t3", package: &package)
            AnnotationEdit.recolor(id: "n1", color: 5, package: &package)
            try package.write(to: opened.directory, fs: fs)

            var reopenIndex = index
            let reopened = try SidecarStore.open(bookPath: path, bookData: data, title: "Origin", index: &reopenIndex, applicationSupport: "/support", fs: fs, now: "t4")
            XCTAssertEqual(reopened.directory, opened.directory, path)
            XCTAssertFalse(reopened.needsReanchor, path)
            let items = AnnotationIndex.items(highlights: reopened.package.highlights.highlights, notes: reopened.package.notes.notes)
            let linked = try XCTUnwrap(items.first { $0.id == "h1" }, path)
            XCTAssertEqual(linked.body, body, path)
            XCTAssertEqual(linked.color, 5, path)
            XCTAssertEqual(linked.quote, "natural selection", path)
            XCTAssertEqual(linked.page, anchor.page, path)
            XCTAssertEqual(linked.cfi, anchor.cfi, path)
            XCTAssertEqual(linked.highlight?.prefix, "called ", path)
            XCTAssertEqual(linked.rects, anchor.rects, path)
            XCTAssertEqual(items.first { $0.id == "h2" }?.hasNote, false, path)
            XCTAssertEqual(items.first { $0.id == "n-solo" }?.body, "standalone", path)
            XCTAssertEqual(reopened.package.state.lastHighlightColor, 5, path)
        }
    }

    func testReadOnlyBookFolderFallsBackToApplicationSupportAndReopens() throws {
        let fs = MemoryFileSystem()
        try fs.createDirectory("/locked")
        try fs.createDirectory("/support")
        fs.readOnly.insert("/locked")
        let data = Data("locked pdf".utf8)
        var index = LibraryIndex()
        let opened = try SidecarStore.open(bookPath: "/locked/Book.pdf", bookData: data, title: "Book", index: &index, applicationSupport: "/support", fs: fs, now: "t0")
        XCTAssertEqual(opened.placement, .applicationSupport)
        var package = opened.package
        addLegacyNote(toSelection: AnnotationAnchor(text: "kept", page: 1, rects: [[0, 0, 4, 4]]), color: 1, highlightID: "h1", noteID: "n1", now: "t", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "survives", now: "t", package: &package)
        try package.write(to: opened.directory, fs: fs)
        let reopened = try SidecarStore.open(bookPath: "/locked/Book.pdf", bookData: data, title: "Book", index: &index, applicationSupport: "/support", fs: fs, now: "t1")
        XCTAssertEqual(reopened.directory, opened.directory)
        XCTAssertEqual(reopened.package.notes.notes.map(\.body), ["survives"])
        XCTAssertEqual(reopened.package.highlights.highlights.map(\.noteID), ["n1"])
    }

    func testPausedVaultFallbackKeepsEditsAndMergesOnlyWhatTheVaultLacks() throws {
        let fs = MemoryFileSystem()
        let directory = "/support/Sidecars/abc.reader"
        let state = PausedVaultState(authoritative: true, baseline: ["notes/Chapter 1.md": "old file"], blockIDs: ["h1", "h2"])
        try state.save(directory: directory, fs: fs)
        XCTAssertEqual(PausedVaultState.load(directory: directory, fs: fs), state)
        XCTAssertNil(PausedVaultState.load(directory: "/nowhere", fs: fs))

        var sidecar = emptyPackage()
        for (id, noteID, text) in [("h1", "n1", "shared"), ("h-paused", "n-paused", "written while paused")] {
            addLegacyNote(toSelection: AnnotationAnchor(text: text, page: 1, rects: [[0, 0, 5, 5]]), color: 1, highlightID: id, noteID: noteID, now: "t", package: &sidecar)
            AnnotationEdit.updateNoteBody(id: noteID, body: "body of \(text)", now: "t", package: &sidecar)
        }
        // The vault loaded the same highlight under its own note id.
        var vault = emptyPackage()
        vault.highlights.highlights = [HighlightEntry(id: "h1", color: 1, page: 1, quote: "shared", noteID: "h1")]
        vault.notes.notes = [NoteEntry(id: "h1", page: 1, quote: "shared", body: "vault body")]
        vault.mergeAnnotations(from: sidecar)
        XCTAssertEqual(vault.highlights.highlights.map(\.id), ["h1", "h-paused"])
        XCTAssertEqual(vault.notes.notes.map(\.id), ["h1", "n-paused"], "no second copy of the shared note")
        XCTAssertEqual(vault.notes.notes.first?.body, "vault body", "existing ids win")

        var typing = emptyPackage()
        addLegacyNote(toSelection: AnnotationAnchor(text: "being typed", page: 1), color: 1, highlightID: "h9", noteID: "n9", now: "t", package: &typing)
        let pruned = typing.pruningBlankNotes()
        XCTAssertTrue(pruned.notes.notes.isEmpty)
        XCTAssertEqual(pruned.highlights.highlights.map(\.id), ["h9"])
        XCTAssertNil(pruned.highlights.highlights[0].noteID)
    }

    func testMultiLineAndFormattedQuoteRoundTripSidecar() throws {
        var package = emptyPackage()
        let quote = "Hard to vary\nacross two lines"
        let body = "> quoted\n\n1. one\n2. two\n\nlink [[Concept]] and <!-- not a comment -->"
        addLegacyNote(toSelection: AnnotationAnchor(text: quote, page: 7, section: "Ch 7", rects: [[1, 2, 3, 4], [5, 6, 7, 8]]), color: 2, highlightID: "h1", noteID: "n1", now: "2026-10-13T00:00:00Z", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: body, now: "2026-10-13T00:00:00Z", package: &package)
        let fs = MemoryFileSystem()
        try package.write(to: "/pkg.reader", fs: fs)
        let read = try SidecarPackage.read(from: "/pkg.reader", fs: fs)
        let item = try XCTUnwrap(AnnotationIndex.items(highlights: read.highlights.highlights, notes: read.notes.notes).first)
        XCTAssertEqual(item.id, "h1")
        XCTAssertEqual(item.body, body)
        XCTAssertEqual(item.rects, [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(item.quote.split(whereSeparator: \.isWhitespace).joined(separator: " "), "Hard to vary across two lines")
    }

    // MARK: Vault merging (BUG-13)

    func testVaultAnnotationSyncPreservesUserProseAndNoPhantomNoteIDs() {
        var package = emptyPackage("book.epub")
        let cfi = EPUBCFI.make(spineIndex: 3, start: 10, end: 22).value
        addLegacyNote(toSelection: AnnotationAnchor(text: "hard to vary", cfi: cfi, section: "Chapter 4"), color: 1, highlightID: "h1", noteID: "n1", now: "t", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "v1", now: "t", package: &package)
        func items() -> [Annotation] { AnnotationIndex.items(highlights: package.highlights.highlights, notes: package.notes.notes) }

        let prose = "my outline\n\t- a typo\n"
        var file = VaultAnnotationSync.render(existing: prose, bookPath: "/book.epub", annotations: items())
        XCTAssertTrue(file.hasPrefix(prose))
        XCTAssertEqual(VaultNoteFile.blocks(file).map(\.id), ["h1"])
        XCTAssertFalse(file.contains("^n1"), "a linked note never gets a block of its own")
        let location = VaultNoteFile.blocks(file).first?.link.location

        AnnotationEdit.recolor(id: "n1", color: 4, package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "v2", now: "t2", package: &package)
        file = VaultAnnotationSync.render(existing: file, bookPath: "/book.epub", annotations: items())
        var blocks = VaultNoteFile.blocks(file)
        XCTAssertEqual(blocks.map(\.id), ["h1"])
        XCTAssertEqual(blocks[0].color, 4)
        XCTAssertEqual(blocks[0].body, "v2")
        XCTAssertEqual(blocks[0].link.location, location)
        XCTAssertTrue(file.hasPrefix(prose))

        AnnotationEdit.removeNoteOnly(id: "h1", package: &package)
        file = VaultAnnotationSync.render(existing: file, bookPath: "/book.epub", annotations: items())
        blocks = VaultNoteFile.blocks(file)
        XCTAssertEqual(blocks.map(\.id), ["h1"], "the highlight keeps its block, now without a body")
        XCTAssertEqual(blocks[0].body, "")

        let remaining = items().filter { $0.id != "h1" }
        file = VaultAnnotationSync.render(existing: file, bookPath: "/book.epub", annotations: remaining, removeIDs: ["h1"])
        XCTAssertTrue(VaultNoteFile.blocks(file).isEmpty)
        XCTAssertTrue(file.hasPrefix(prose))
    }

    func testVaultSyncExternalEditAndConflictPreservation() {
        var package = emptyPackage("book.epub")
        let cfi = EPUBCFI.make(spineIndex: 0, start: 1, end: 5).value
        for (id, noteID, text, body) in [("h1", "n1", "alpha", "first"), ("h2", "n2", "beta", "second")] {
            addLegacyNote(toSelection: AnnotationAnchor(text: text, cfi: cfi + id, section: "Chapter 1"), color: 1, highlightID: id, noteID: noteID, now: "t", package: &package)
            AnnotationEdit.updateNoteBody(id: noteID, body: body, now: "t", package: &package)
        }
        func items() -> [Annotation] { AnnotationIndex.items(highlights: package.highlights.highlights, notes: package.notes.notes) }
        let prose = "freeform prose\n"
        let written = VaultAnnotationSync.render(existing: prose, bookPath: "/book.epub", annotations: items())

        // The pending set is keyed like the file: one block per annotation, by highlight id.
        let baseline = Dictionary(uniqueKeysWithValues: items().map { ($0.id, OwnedBlocks.body(id: $0.id, in: written) ?? "") })
        XCTAssertEqual(Set(baseline.keys), ["h1", "h2"], "no entry for n1 or n2")
        let pending = baseline

        // Disk edits h1 while Reader has no pending change: disk wins, nothing new is injected.
        let outside = OwnedBlocks.upsert(written, id: "h1", body: baseline["h1"]!.replacingOccurrences(of: "first", with: "edited in Obsidian"))
        let adopted = VaultSync.applyExternal(VaultSyncState(disk: written, pending: pending, written: baseline), disk: outside)
        XCTAssertTrue(adopted.conflicts.isEmpty)
        XCTAssertTrue(adopted.state.disk.contains("edited in Obsidian"))
        XCTAssertFalse(adopted.state.disk.contains("^n1"))
        XCTAssertFalse(adopted.state.disk.contains("^n2"))
        XCTAssertTrue(adopted.state.disk.hasPrefix(prose))

        // Reader has typed into h2 while disk edited h1: both survive.
        var typing = pending
        typing["h2"] = baseline["h2"]!.replacingOccurrences(of: "second", with: "typed in Reader")
        let both = VaultSync.applyExternal(VaultSyncState(disk: written, pending: typing, written: baseline), disk: outside)
        XCTAssertTrue(both.conflicts.isEmpty)
        XCTAssertTrue(both.state.disk.contains("edited in Obsidian"))
        XCTAssertTrue(OwnedBlocks.body(id: "h2", in: both.state.disk)?.contains("typed in Reader") == true)

        // Both sides change h1: both versions are kept and the id is flagged, still without n1.
        typing = pending
        typing["h1"] = baseline["h1"]!.replacingOccurrences(of: "first", with: "typed in Reader")
        let clash = VaultSync.applyExternal(VaultSyncState(disk: written, pending: typing, written: baseline), disk: outside)
        XCTAssertEqual(clash.conflicts, ["h1"])
        XCTAssertTrue(clash.state.disk.contains("typed in Reader"))
        XCTAssertTrue(clash.state.disk.contains("edited in Obsidian"))
        XCTAssertFalse(clash.state.disk.contains("^n1"))
        XCTAssertEqual(VaultNoteFile.blocks(clash.state.disk).map(\.id), ["h1", "h2"])

        // The three-way merge keys blocks the same way, so a linked note never gets a block of its own.
        AnnotationEdit.updateNoteBody(id: "n2", body: "second, revised", now: "t2", package: &package)
        let merged = VaultAnnotationSync.merge(baseline: written, disk: outside, bookPath: "/book.epub", annotations: items())
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertEqual(VaultNoteFile.blocks(merged.text).map(\.id), ["h1", "h2"])
        XCTAssertFalse(merged.text.contains("^n2"))
        XCTAssertTrue(merged.text.contains("edited in Obsidian"))
        XCTAssertEqual(VaultNoteFile.blocks(merged.text).first { $0.id == "h2" }?.body, "second, revised")
        XCTAssertTrue(merged.text.hasPrefix(prose))
    }

    func testPassageIdentityAcrossPDFEPUBAndMarkdown() {
        XCTAssertTrue(PassageIdentity.same(quote: "q", page: 1, cfi: nil, otherQuote: "q", otherPage: 1, otherCFI: "page=1"))
        XCTAssertFalse(PassageIdentity.same(quote: "q", page: 1, cfi: nil, otherQuote: "q", otherPage: 2, otherCFI: nil))
        let epub = EPUBCFI.make(spineIndex: 1, start: 1, end: 2).value
        XCTAssertTrue(PassageIdentity.same(quote: "q", page: nil, cfi: epub, otherQuote: "q", otherPage: nil, otherCFI: epub))
        XCTAssertFalse(PassageIdentity.same(quote: "q", page: nil, cfi: epub, otherQuote: "q", otherPage: nil, otherCFI: EPUBCFI.make(spineIndex: 1, start: 9, end: 10).value))
        XCTAssertTrue(PassageIdentity.same(quote: "q", page: nil, cfi: "mdloc(s=1,a=x,o=1,e=2)", otherQuote: "q", otherPage: nil, otherCFI: "mdloc(s=1,a=x,o=1,e=2)"))
        XCTAssertFalse(PassageIdentity.same(quote: "q", page: nil, cfi: "mdloc(s=1,a=x,o=1,e=2)", otherQuote: "q", otherPage: nil, otherCFI: "mdloc(s=1,a=x,o=40,e=41)"))

        // A second legitimate note on another page is never dropped as a duplicate.
        var highlights = [HighlightEntry(id: "h1", color: 1, page: 1, quote: "same words", noteID: "n1")]
        var notes = [
            NoteEntry(id: "n1", page: 1, quote: "same words", body: "one"),
            NoteEntry(id: "n2", page: 5, quote: "same words", body: "two"),
        ]
        AnnotationEdit.dropDuplicateNotes(highlights: &highlights, notes: &notes)
        XCTAssertEqual(notes.map(\.id), ["n1", "n2"])
    }
}

/// Sidecars written before a highlight's note shared the highlight's id still hold a separate
/// note id. `AnnotationEdit.addNote` now always reuses the highlight id, so these lifecycle tests
/// relink the note to the id they name, which is how such older records look on disk.
private func addLegacyNote(toSelection anchor: AnnotationAnchor, color: Int, highlightID: String?, noteID: String, now: String, package: inout SidecarPackage) {
    _ = AnnotationEdit.addNote(toSelection: anchor, color: color, highlightID: highlightID, noteID: noteID, now: now, package: &package)
    guard let highlightID, highlightID != noteID,
          let highlight = package.highlights.highlights.firstIndex(where: { $0.id == highlightID }),
          let note = package.notes.notes.firstIndex(where: { $0.id == highlightID }) else { return }
    package.notes.notes[note].id = noteID
    package.highlights.highlights[highlight].noteID = noteID
}
