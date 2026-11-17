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
}
