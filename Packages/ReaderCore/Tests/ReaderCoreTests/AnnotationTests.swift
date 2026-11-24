import Foundation
import ReaderCore
import XCTest

final class AnnotationTests: XCTestCase {
    func testReadingOrderGroupingFiltersAndNearest() {
        let top = HighlightEntry(id: "h-top", color: 1, page: 1, quote: "alpha", section: "Chapter 1", rects: [[10, 400, 80, 420]])
        let bottom = HighlightEntry(id: "h-bottom", color: 3, page: 1, quote: "beta café", section: "Chapter 1", rects: [[30, 10, 90, 30]])
        let later = HighlightEntry(id: "h-later", color: 1, page: 2, quote: "gamma", section: "Chapter 2", rects: [[0, 100, 10, 110]])
        let legacy = NoteEntry(id: "n-old", page: 2, quote: "delta", section: "Chapter 2", created: "2026-10-01T00:00:00Z", body: "older note")
        let note = NoteEntry(id: "n-top", page: 1, quote: "alpha", section: "Chapter 1", created: "2026-10-02T00:00:00Z", updated: "2026-10-13T00:00:00Z", body: "A note")
        var highlights = [later, bottom, top]
        highlights[2].noteID = "n-top"
        let items = AnnotationIndex.items(highlights: highlights, notes: [legacy, note])
        XCTAssertEqual(items.map(\.id), ["h-top", "h-bottom", "h-later", "n-old"])
        XCTAssertEqual(items[0].note?.body, "A note")
        let groups = AnnotationIndex.grouped(items)
        XCTAssertEqual(groups.map(\.title), ["Chapter 1", "Chapter 2"])
        XCTAssertEqual(AnnotationIndex.filter(items, query: "Cafe").map(\.id), ["h-bottom"])
        XCTAssertEqual(AnnotationIndex.filter(items, kind: .notes).map(\.id), ["h-top", "n-old"])
        XCTAssertEqual(AnnotationIndex.filter(items, kind: .color(1)).map(\.id), ["h-top", "h-later"])
        let counts = AnnotationIndex.counts(items)
        XCTAssertEqual(counts.notes, 2)
        XCTAssertEqual(counts.colors[1], 2)
        XCTAssertEqual(counts.colors[3], 1)
        let recent = AnnotationIndex.sort(items, .recentlyEdited)
        XCTAssertEqual(recent.first?.id, "h-top")
        XCTAssertEqual(AnnotationIndex.nearest(items, to: 2)?.page, 2)
    }

    func testEPUBOrderUsesSpineThenCFI() {
        let early = HighlightEntry(id: "a", color: 1, cfi: EPUBCFI.make(spineIndex: 0, start: 20, end: 30).value, quote: "early")
        let late = HighlightEntry(id: "b", color: 1, cfi: EPUBCFI.make(spineIndex: 3, start: 1, end: 4).value, quote: "late")
        let mid = HighlightEntry(id: "c", color: 1, cfi: EPUBCFI.make(spineIndex: 0, start: 80, end: 90).value, quote: "mid")
        let items = AnnotationIndex.items(highlights: [late, mid, early], notes: [])
        XCTAssertEqual(items.map(\.id), ["a", "c", "b"])
    }

    func testPDFPageLocationIsTheSamePassageAndEmptyNoteIsNotASecondBlock() {
        XCTAssertNil(PassageIdentity.cfi("page=1"))
        XCTAssertEqual(PassageIdentity.cfi("epubcfi(/6/4)"), "epubcfi(/6/4)")
        XCTAssertTrue(PassageIdentity.same(quote: "hard to vary", page: 1, cfi: nil, otherQuote: "hard to vary", otherPage: 1, otherCFI: "page=1"))
        XCTAssertFalse(PassageIdentity.same(quote: "hard to vary", page: 1, cfi: nil, otherQuote: "hard to vary", otherPage: 2, otherCFI: "page=2"))
        let highlight = HighlightEntry(id: "h1", color: 1, page: 1, cfi: "page=1", quote: "hard to vary")
        let note = NoteEntry(id: "n1", page: 1, cfi: nil, quote: "hard to vary", body: "")
        let shown = AnnotationIndex.items(highlights: [highlight], notes: [note])
        XCTAssertEqual(shown.map(\.id), ["h1"])
        XCTAssertEqual(shown.first?.note?.id, "n1")
        var highlights = [HighlightEntry(id: "h1", color: 1, page: 1, cfi: "page=1", quote: "hard to vary", noteID: "n1")]
        var notes = [note]
        AnnotationEdit.dropDuplicateNotes(highlights: &highlights, notes: &notes)
        XCTAssertEqual(notes.map(\.id), ["n1"])
        let written = VaultAnnotationSync.render(
            existing: "",
            bookPath: "/Book.pdf",
            annotations: [
                Annotation(highlight: HighlightEntry(id: "h1", color: 1, page: 1, quote: "hard to vary"), note: nil),
                Annotation(highlight: nil, note: note),
            ]
        )
        XCTAssertEqual(VaultNoteFile.blocks(written).map(\.id), ["h1"])
    }

    func testEditingKeepsIdsAndDropsTheRewrittenCopy() {
        var package = SidecarPackage.empty(identity: FrontMatter(kind: "notes", document: "Book.pdf", fingerprint: "sha256:x"))
        let anchor = AnnotationAnchor(text: "hard to vary", page: 4, section: "Chapter 4")
        _ = AnnotationEdit.addNote(toSelection: anchor, color: 1, highlightID: "h1", noteID: "n1", now: "t", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "typed", now: "t2", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "typed more", now: "t3", package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h1"])
        XCTAssertEqual(package.notes.notes.map(\.id), ["n1"])
        XCTAssertEqual(AnnotationIndex.items(highlights: package.highlights.highlights, notes: package.notes.notes).map(\.id), ["h1"])
        var highlights = [HighlightEntry(id: "h1", color: 1, page: 4, quote: "hard to vary", noteID: "h1")]
        var notes = [
            NoteEntry(id: "h1", page: 4, quote: "hard to vary", body: "typed more"),
            NoteEntry(id: "n1", page: 4, quote: "hard to vary", body: "typed more"),
        ]
        AnnotationEdit.dropDuplicateNotes(highlights: &highlights, notes: &notes)
        let shown = AnnotationIndex.items(highlights: highlights, notes: notes)
        XCTAssertEqual(notes.map(\.id), ["h1"])
        XCTAssertEqual(shown.map(\.id), ["h1"])
        XCTAssertEqual(shown.first?.body, "typed more")
        let cache = ConceptLabelCache()
        let concepts = [Concept(id: "C1", title: "Hard", chapter: 4, findTerms: ["hard"])]
        let first = cache.labels(id: "h1", quote: "hard to vary", concepts: concepts, chapter: 4)
        let second = cache.labels(id: "h1", quote: "hard to vary", concepts: [Concept(id: "C9", title: "Other", findTerms: ["other"])], chapter: 4)
        XCTAssertEqual(first, ["C1"])
        XCTAssertEqual(second, first)
    }

    func testAddUpdateRemoveAndEmptyBody() {
        var package = SidecarPackage.empty(identity: FrontMatter(kind: "notes", document: "Book.pdf", fingerprint: "sha256:x"))
        let selection = AnnotationAnchor(text: "hard to vary", page: 4, section: "Chapter 4", rects: [[1, 2, 3, 4]])
        let created = AnnotationEdit.addNote(toSelection: selection, color: 2, highlightID: "h1", noteID: "n1", now: "2026-10-13T00:00:00Z", package: &package)
        XCTAssertEqual(created.highlight?.noteID, "n1")
        XCTAssertEqual(package.highlights.highlights.count, 1)
        XCTAssertEqual(package.notes.notes.count, 1)
        XCTAssertEqual(package.state.lastHighlightColor, 2)
        AnnotationEdit.updateNoteBody(id: "n1", body: "  A real note  ", now: "2026-10-14T00:00:00Z", package: &package)
        XCTAssertEqual(package.notes.notes.first?.body, "A real note")
        AnnotationEdit.recolor(id: "h1", color: 5, package: &package)
        XCTAssertEqual(package.highlights.highlights.first?.color, 5)
        AnnotationEdit.updateNoteBody(id: "n1", body: "Write a note…", now: "2026-10-15T00:00:00Z", package: &package)
        XCTAssertTrue(package.notes.notes.isEmpty)
        XCTAssertNil(package.highlights.highlights.first?.noteID)
        XCTAssertEqual(package.highlights.highlights.count, 1)
        AnnotationEdit.addNote(toHighlight: "h1", noteID: "n2", now: "2026-10-16T00:00:00Z", package: &package)
        XCTAssertEqual(package.highlights.highlights.first?.noteID, "n2")
        AnnotationEdit.removeNote(id: "n2", package: &package)
        XCTAssertNil(package.highlights.highlights.first?.noteID)
        XCTAssertEqual(package.highlights.highlights.count, 1)
        AnnotationEdit.addNote(toHighlight: "h1", noteID: "n3", now: "2026-10-16T00:00:00Z", package: &package)
        AnnotationEdit.removeHighlightAndNote(id: "h1", package: &package)
        XCTAssertTrue(package.highlights.highlights.isEmpty)
        XCTAssertTrue(package.notes.notes.isEmpty)
    }

    func testCopyLinkAndHighlightPalette() {
        let link = CopyLink.make(path: "/Book.pdf", page: 4, cfi: nil, quote: "hard to vary")
        let parsed = ReaderLink.parse(link.url)
        XCTAssertEqual(parsed?.path, "/Book.pdf")
        XCTAssertEqual(parsed?.location, "page=4&quote=hard to vary")
        let light = HighlightAppearance.components(color: 1, dark: false)
        let dark = HighlightAppearance.components(color: 1, dark: true)
        XCTAssertEqual(light?.a, HighlightAppearance.opacity)
        XCTAssertEqual(HighlightAppearance.blendMode, "multiply")
        XCTAssertNotEqual(light?.r, dark?.r)
        XCTAssertNil(HighlightAppearance.components(color: 9, dark: false))
    }

    func testBatchRemovalRestoresIdsColorsAndOrder() {
        var package = SidecarPackage.empty(identity: FrontMatter(kind: "notes", document: "Book.pdf", fingerprint: "sha256:x"))
        let anchors = [
            AnnotationAnchor(text: "alpha", page: 1, section: "Chapter 1", rects: [[0, 10, 4, 14]]),
            AnnotationAnchor(text: "beta", page: 1, section: "Chapter 1", rects: [[0, 20, 4, 24]]),
            AnnotationAnchor(text: "gamma", page: 2, section: "Chapter 2", rects: [[0, 8, 4, 12]]),
        ]
        for (index, anchor) in anchors.enumerated() {
            _ = AnnotationEdit.addNote(toSelection: anchor, color: index + 1, highlightID: "h\(index + 1)", noteID: "n\(index + 1)", now: "2026-10-13T00:00:00Z", package: &package)
            AnnotationEdit.updateNoteBody(id: "n\(index + 1)", body: "Note \(index + 1)", now: "2026-10-13T00:00:00Z", package: &package)
        }
        let originalHighlights = package.highlights.highlights
        let originalNotes = package.notes.notes
        AnnotationEdit.remove(ids: ["h1", "h3"], package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h2"])
        XCTAssertEqual(package.notes.notes.map(\.id), ["n2"])
        XCTAssertEqual(package.highlights.highlights.first?.color, 2)
        AnnotationEdit.restore(highlights: originalHighlights, notes: originalNotes, package: &package)
        XCTAssertEqual(package.highlights.highlights.map(\.id), ["h1", "h2", "h3"])
        XCTAssertEqual(package.highlights.highlights.map(\.color), [1, 2, 3])
        XCTAssertEqual(package.notes.notes.map(\.id), ["n1", "n2", "n3"])
        XCTAssertEqual(package.notes.notes.map(\.body), ["Note 1", "Note 2", "Note 3"])

        let user = "freeform outline\n\t- a typo here\n"
        let items = AnnotationIndex.items(highlights: originalHighlights, notes: originalNotes)
        let file = VaultAnnotationSync.render(existing: user, bookPath: "/book.epub", annotations: items)
        XCTAssertTrue(file.hasPrefix(user))
        let kept = items.filter { $0.id == "h2" }
        let stripped = VaultAnnotationSync.render(existing: file, bookPath: "/book.epub", annotations: kept, removeIDs: ["h1", "h3"])
        XCTAssertTrue(stripped.hasPrefix(user))
        XCTAssertEqual(VaultNoteFile.blocks(stripped).map(\.id), ["h2"])
        XCTAssertFalse(stripped.contains("id=h1"))
        XCTAssertFalse(stripped.contains("id=h3"))
        let restored = VaultAnnotationSync.render(existing: stripped, bookPath: "/book.epub", annotations: items, removeIDs: [])
        XCTAssertTrue(restored.hasPrefix(user))
        let blocks = VaultNoteFile.blocks(restored)
        XCTAssertEqual(blocks.map(\.id), ["h2", "h1", "h3"])
        XCTAssertEqual(blocks.map(\.color), [2, 1, 3])
        XCTAssertEqual(blocks.map(\.body), ["Note 2", "Note 1", "Note 3"])
    }

    func testAddHighlightUndoShapeAndNoteOnlyAndPaths() throws {
        var package = SidecarPackage.empty(identity: FrontMatter(kind: "notes", document: "Book.pdf", fingerprint: "sha256:x"))
        let anchor = AnnotationAnchor(text: "hard to vary", page: 4, section: "Chapter 4")
        let created = AnnotationEdit.addHighlight(selection: anchor, color: 2, id: "h1", package: &package)
        XCTAssertEqual(created?.id, "h1")
        XCTAssertEqual(created?.color, 2)
        XCTAssertEqual(AnnotationIndex.highlight(matchingQuote: "hard to vary", page: 4, cfi: nil, in: package.highlights.highlights)?.id, "h1")
        let again = AnnotationEdit.addHighlight(selection: anchor, color: 5, id: "h2", package: &package)
        XCTAssertEqual(again?.id, "h1")
        XCTAssertEqual(package.highlights.highlights.count, 1)
        let pageNote = AnnotationEdit.addNote(toSelection: AnnotationAnchor(text: "Page note", page: 1), color: 1, highlightID: nil, noteID: "n-page", now: "t", package: &package)
        XCTAssertNil(pageNote.highlight)
        XCTAssertEqual(pageNote.note?.id, "n-page")
        AnnotationEdit.updateNoteBody(id: "n1", body: "", now: "t2", package: &package)
        _ = AnnotationEdit.addNote(toSelection: anchor, color: 2, highlightID: "h1", noteID: "n1", now: "t", package: &package)
        AnnotationEdit.updateNoteBody(id: "n1", body: "   ", now: "t3", package: &package)
        XCTAssertEqual(package.highlights.highlights.count, 1)
        XCTAssertNil(package.highlights.highlights.first?.noteID)
        XCTAssertFalse(package.notes.notes.contains { $0.id == "n1" })
        XCTAssertTrue(Paths.isSafeRelative("notes"))
        XCTAssertTrue(Paths.isSafeRelative("learner/vocabulary.md"))
        XCTAssertFalse(Paths.isSafeRelative("../notes"))
        XCTAssertFalse(Paths.isSafeRelative("/tmp/notes"))
        let file = ObsidianLink.noteFile(vaultRoot: "/SecondBrain", bookFolder: "/SecondBrain/books/beginning-of-infinity", notesFolder: "notes", chapter: 4, bookTitle: "Beginning of Infinity")
        XCTAssertEqual(file, "books/beginning-of-infinity/notes/Chapter 4.md")
        XCTAssertEqual(ObsidianLink.displayPath(vaultRoot: "/SecondBrain", absolute: "/SecondBrain/books/boi/learner/vocabulary.md"), "books/boi/learner/vocabulary.md")
        let block = VaultNoteBlock(id: "h9", quote: "page quote", body: "", color: 1, link: ReaderLink(path: "/b.pdf", location: "page=12", id: "h9"))
        let rendered = VaultNoteFile.upsert("", block: block)
        XCTAssertEqual(VaultNoteFile.blocks(rendered).first?.link.pageNumber, 12)
        let fs = MemoryFileSystem()
        try fs.createDirectory("/SecondBrain/.obsidian")
        try fs.createDirectory("/SecondBrain/books/boi")
        var disabled = VaultBookSettings()
        disabled.enabled = false
        try disabled.save(bookFolder: "/SecondBrain/books/boi", fs: fs)
        let located = VaultFinder.locate(bookPath: "/SecondBrain/books/boi/book.pdf", fs: fs)
        let loaded = VaultBookSettings.load(bookFolder: "/SecondBrain/books/boi", fs: fs)
        XCTAssertEqual(located?.vaultName, "SecondBrain")
        XCTAssertFalse(loaded.enabled)
    }

    func testMarginStackHeadingAndBookmarkToggle() {
        let stacked = MarginLayout.stack([("lower", 90), ("upper", 140)], height: 54)
        XCTAssertEqual(stacked.map(\.id), ["upper", "lower"])
        XCTAssertEqual(stacked.map(\.y), [140, 82])
        XCTAssertTrue(EPUBHeading.hasHeading(xhtml: "<h1>Chapter</h1><p>text</p>"))
        XCTAssertFalse(EPUBHeading.hasHeading(xhtml: "<p>No title here</p>"))
        var bookmarks = [Bookmark(id: "b1", page: 3, title: "Three")]
        XCTAssertNil(BookmarkEdit.toggle(page: 3, cfi: nil, title: "Three", section: nil, id: "b2", bookmarks: &bookmarks))
        XCTAssertTrue(bookmarks.isEmpty)
        XCTAssertNotNil(BookmarkEdit.toggle(page: nil, cfi: "epubcfi(/6/4)", title: "Chapter", section: "Chapter 1", id: "b3", bookmarks: &bookmarks))
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertTrue(HighlightAppearance.css(dark: true).contains(".reader-hl-1"))
    }

    func testExportMatchesVaultCallout() {
        let highlight = HighlightEntry(id: "h1", color: 1, page: 4, cfi: "page=4", quote: "hard to vary", section: "Chapter 4", noteID: "n1")
        let note = NoteEntry(id: "n1", page: 4, quote: "hard to vary", section: "Chapter 4", body: "A note of mine.")
        let items = AnnotationIndex.items(highlights: [highlight], notes: [note])
        let markdown = AnnotationExport.markdown(book: "Beginning of Infinity", items: items, path: "/book.epub")
        XCTAssertTrue(markdown.contains("# Notes — Beginning of Infinity"))
        XCTAssertTrue(markdown.contains("## Chapter 4"))
        XCTAssertTrue(markdown.contains("> [!quote] yellow"))
        XCTAssertTrue(markdown.contains("> hard to vary"))
        XCTAssertTrue(markdown.contains("A note of mine."))
        XCTAssertTrue(markdown.contains("[↗ Open in Reader](reader://open?"))
        XCTAssertTrue(markdown.contains("^h1"))
    }

    func testVaultRoundTripKeepsLegacyIDsAndUserText() {
        let user = "freeform outline\n\t- a typo here\n"
        let legacy = VaultNoteBlock(
            id: "n-old",
            quote: "handwritten passage",
            body: "my outline note",
            link: ReaderLink(path: "/book.epub", location: "epubcfi(/6/8!/4,/1:10,/1:20)", id: "n-old")
        )
        let highlight = VaultNoteBlock(
            id: "h1",
            quote: "hard to vary",
            body: "",
            color: 1,
            link: ReaderLink(path: "/book.epub", location: "epubcfi(/6/8!/4,/1:89,/1:130)", id: "h1")
        )
        let original = VaultNoteFile.upsert(VaultNoteFile.upsert(user, block: legacy), block: highlight)
        XCTAssertTrue(original.hasPrefix(user))
        let linked = Annotation(
            highlight: HighlightEntry(id: "h1", color: 4, cfi: "epubcfi(/6/10!/4,/1:211,/1:222)", quote: "hard to vary", section: "Chapter 4", noteID: "n1"),
            note: NoteEntry(id: "n1", cfi: "epubcfi(/6/10!/4,/1:211,/1:222)", quote: "hard to vary", section: "Chapter 4", body: "added later")
        )
        let kept = Annotation(highlight: nil, note: NoteEntry(id: "n-old", quote: "handwritten passage", body: "my outline note"))
        let updated = VaultAnnotationSync.render(existing: original, bookPath: "/book.epub", annotations: [linked, kept], removeIDs: [])
        XCTAssertTrue(updated.hasPrefix(user))
        let blocks = VaultNoteFile.blocks(updated)
        XCTAssertEqual(blocks.first { $0.id == "h1" }?.link.location, "epubcfi(/6/8!/4,/1:89,/1:130)")
        XCTAssertEqual(blocks.first { $0.id == "h1" }?.body, "added later")
        XCTAssertEqual(blocks.first { $0.id == "h1" }?.color, 4)
        XCTAssertEqual(blocks.first { $0.id == "n-old" }?.body, "my outline note")
        XCTAssertFalse(blocks.contains { $0.id == "n1" })
        let removed = VaultAnnotationSync.render(existing: updated, bookPath: "/book.epub", annotations: [kept], removeIDs: ["h1"])
        XCTAssertTrue(removed.hasPrefix(user))
        XCTAssertNil(VaultNoteFile.blocks(removed).first { $0.id == "h1" })
        XCTAssertNotNil(VaultNoteFile.blocks(removed).first { $0.id == "n-old" })
    }

    func testHighlightPaintStaysOnTheRecordedChapter() {
        let cfi = EPUBCFI.make(spineIndex: 0, start: 11, end: 23).value
        let highlight = HighlightEntry(
            id: "h1",
            color: 1,
            cfi: cfi,
            quote: "hard to vary",
            prefix: "is ",
            suffix: " because",
            section: "Chapter 1"
        )
        let marks = HighlightPaint.marks(for: [highlight])
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].spineIndex, 0)
        XCTAssertEqual(marks[0].chapter, 1)
        let text = "An idea is hard to vary because it explains."
        XCTAssertNotNil(HighlightPaint.occurrence(of: marks[0], in: text, chapter: 1, spineIndex: 0))
        XCTAssertNil(HighlightPaint.occurrence(of: marks[0], in: text, chapter: 2, spineIndex: 1))
        XCTAssertNil(HighlightPaint.occurrence(of: marks[0], in: "hard to vary later", chapter: 1, spineIndex: 0))
        var byChapter = marks[0]
        byChapter.spineIndex = nil
        XCTAssertNotNil(HighlightPaint.occurrence(of: byChapter, in: text, chapter: 1, spineIndex: nil))
        XCTAssertNil(HighlightPaint.occurrence(of: byChapter, in: text, chapter: 2, spineIndex: nil))
    }

    func testFindSelectsTheFirstMatchInsteadOfTheNext() {
        XCTAssertEqual(FindSelection.index(starts: [10, 40, 80], cursor: 0), 0)
        XCTAssertEqual(FindSelection.index(starts: [10, 40], cursor: 10), 0)
        XCTAssertEqual(FindSelection.index(starts: [1, 2], cursor: 1), 0)
        XCTAssertEqual(FindSelection.index(starts: [10, 40], cursor: 15), 1)
        XCTAssertEqual(FindSelection.index(starts: [10, 40], cursor: 90), 0)
        XCTAssertEqual(FindSelection.step(count: 3, current: 0, forward: true), 1)
        XCTAssertNil(FindSelection.index(starts: [], cursor: 0))
        let typed = "quick brown fox"
        XCTAssertEqual(FindQuery.command(query: typed, previous: "quick brown fo", hasMatches: true, committed: false), .begin)
        XCTAssertEqual(FindQuery.command(query: typed, previous: typed, hasMatches: true, committed: false), .stay)
        XCTAssertEqual(FindQuery.command(query: typed, previous: typed, hasMatches: true, committed: true), .step)
        XCTAssertEqual(FindQuery.command(query: typed, previous: typed, hasMatches: false, committed: true), .begin)
    }
}
