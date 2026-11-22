import Foundation
import ReaderCore
import XCTest

final class CoreTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.fingerprint(Data("abc".utf8)), "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPDFIdentifierScan() {
        let sample = Data("trailer /ID [<4B1E77C0><99AA>] >>".utf8)
        XCTAssertEqual(PDFIdentity.scan(sample), "4b1e77c0")
        XCTAssertNil(PDFIdentity.scan(Data("no id here".utf8)))
    }

    func testCommentSurvivesDoubleDash() {
        let value = JSONValue.object(["quote": .string("a --> b")])
        let line = ReaderComment.render(value)
        XCTAssertFalse(line.dropLast(3).contains("-->"))
        let parsed = ReaderComment.parse(line: line)
        XCTAssertEqual(parsed?["quote"]?.string, "a --> b")
    }

    func testNotesRoundTripAndSpecShape() {
        let matter = FrontMatter(kind: "notes", document: "On the Origin of Species.pdf", fingerprint: "sha256:abc", pdfID: "4b1e")
        let note = NoteEntry(
            id: "n_01HZX1",
            page: 62,
            quote: "we often see superabundance of food",
            prefix: "bright with gladness, ",
            suffix: "; we do not see",
            section: "Ch. 3 · Struggle for Existence",
            created: "2026-11-14T20:51:00Z",
            body: "Abundance hides constant destruction."
        )
        let document = NotesDocument(frontMatter: matter, notes: [note])
        let rendered = document.render()
        XCTAssertTrue(rendered.contains("reader: notes"))
        XCTAssertTrue(rendered.contains("<!-- reader "))
        XCTAssertTrue(rendered.contains("> we often see superabundance of food"))
        let parsed = NotesDocument.parse(rendered)
        XCTAssertEqual(parsed.notes, [note])
        XCTAssertEqual(parsed.frontMatter.fingerprint, matter.fingerprint)
        XCTAssertEqual(parsed.frontMatter.pdfID, "4b1e")
    }

    func testHighlightsRoundTripAndInvalidColor() {
        let matter = FrontMatter(kind: "highlights", document: "Book.pdf", fingerprint: "sha256:ff")
        let highlight = HighlightEntry(
            id: "h1",
            color: 1,
            page: 62,
            quote: "we do not see, or we forget",
            prefix: "of food; ",
            suffix: ", that the birds",
            section: "Ch. 3",
            rects: [[72.0, 188.3, 540.2, 230.9]],
            noteID: "n1"
        )
        let rendered = HighlightsDocument(frontMatter: matter, highlights: [highlight]).render()
        let parsed = HighlightsDocument.parse(rendered)
        XCTAssertEqual(parsed.highlights, [highlight])
        let broken = rendered.replacingOccurrences(of: "\"color\":1", with: "\"color\":9")
        let rejected = HighlightsDocument.parse(broken)
        XCTAssertTrue(rejected.highlights.isEmpty)
        XCTAssertFalse(rejected.warnings.isEmpty)
    }

    func testViewStateJSONRoundTrip() throws {
        let state = ViewState(
            page: 12,
            scrollY: 0.42,
            zoom: 1.35,
            fitMode: .custom,
            continuous: false,
            twoPages: true,
            sidebar: .bookmarks,
            panelVisible: false,
            panelTab: .highlights,
            rotations: ["3": 90],
            bookmarks: [Bookmark(id: "b1", page: 12, title: "Here")],
            lastHighlightColor: 4,
            windowFrame: StoredWindowFrame(x: 40, y: 80, width: 1200, height: 860)
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ViewState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.fitMode, .custom)
        XCTAssertEqual(decoded.scrollY, 0.42)
        XCTAssertEqual(decoded.windowFrame?.width, 1200)
        XCTAssertEqual(decoded.continuous, false)
        XCTAssertEqual(decoded.twoPages, true)
        XCTAssertEqual(decoded.page, 12)

        let legacy = """
        {"bookmarks":[],"continuous":true,"fitMode":"fitWidth","lastHighlightColor":1,"page":4,"panelTab":"notes","panelVisible":true,"rotations":{},"scrollY":0.2,"sidebar":"thumbnails","twoPages":false,"version":1,"zoom":1.1}
        """
        let older = try JSONDecoder().decode(ViewState.self, from: Data(legacy.utf8))
        XCTAssertEqual(older.page, 4)
        XCTAssertEqual(older.fitMode, .fitWidth)
        XCTAssertEqual(older.scrollY, 0.2)
        XCTAssertEqual(older.zoom, 1.1)
        XCTAssertNil(older.windowFrame)
        XCTAssertEqual(older.sidebar, .thumbnails)
    }

    func testSidecarStateFileRoundTrip() throws {
        let fs = MemoryFileSystem()
        try fs.createDirectory("/books")
        let identity = FrontMatter(kind: "notes", document: "Book.pdf", fingerprint: "sha256:abc")
        var package = SidecarPackage.empty(identity: identity)
        package.state = ViewState(
            page: 7,
            scrollY: 0.15,
            zoom: 2,
            fitMode: .actual,
            continuous: true,
            twoPages: false,
            windowFrame: StoredWindowFrame(x: 1, y: 2, width: 900, height: 700)
        )
        try package.write(to: "/books/Book.reader", fs: fs)
        let raw = try fs.readString("/books/Book.reader/state.json")
        XCTAssertTrue(raw.contains("actual"))
        XCTAssertTrue(raw.contains("windowFrame"))
        let loaded = try SidecarPackage.read(from: "/books/Book.reader", fs: fs)
        XCTAssertEqual(loaded.state.page, 7)
        XCTAssertEqual(loaded.state.scrollY, 0.15)
        XCTAssertEqual(loaded.state.zoom, 2)
        XCTAssertEqual(loaded.state.fitMode, .actual)
        XCTAssertEqual(loaded.state.continuous, true)
        XCTAssertEqual(loaded.state.twoPages, false)
        XCTAssertEqual(loaded.state.windowFrame, package.state.windowFrame)
    }

    func testDeletedHighlightRoundTripsOutOfHighlightsFile() {
        let matter = FrontMatter(kind: "highlights", document: "Book.pdf", fingerprint: "sha256:ff")
        let keep = HighlightEntry(id: "h_keep", color: 2, page: 10, quote: "kept sentence", prefix: "a ", suffix: " b", section: "Ch. 1")
        let drop = HighlightEntry(id: "h_drop", color: 5, page: 11, quote: "delete me", prefix: "", suffix: "", section: "Ch. 1")
        var document = HighlightsDocument(frontMatter: matter, highlights: [keep, drop])
        let removed = document.removeHighlight(id: "h_drop")
        XCTAssertEqual(removed?.id, "h_drop")
        XCTAssertNil(document.removeHighlight(id: "missing"))
        let rendered = document.render()
        XCTAssertFalse(rendered.contains("h_drop"))
        XCTAssertFalse(rendered.contains("delete me"))
        XCTAssertTrue(rendered.contains("h_keep"))
        let parsed = HighlightsDocument.parse(rendered)
        XCTAssertEqual(parsed.highlights.map(\.id), ["h_keep"])
        XCTAssertEqual(parsed.highlights.first?.quote, "kept sentence")
        XCTAssertTrue(document.containsSameRange(quote: "kept sentence", page: 10, cfi: nil))
        XCTAssertFalse(document.containsSameRange(quote: "kept sentence", page: 11, cfi: nil))
    }

    func testWordsRoundTripUndoAndOrphanBullet() {
        let matter = FrontMatter(kind: "words", document: "On the Origin of Species.pdf", fingerprint: "sha256:abc")
        let lookup = LookupEntry(
            id: "l1",
            page: 63,
            section: "Ch. 3",
            quote: "progeny",
            prefix: "covered by the ",
            suffix: " of a single pair",
            sentence: "the earth would soon be covered by the progeny of a single pair.",
            date: "2026-11-14T21:12:00Z"
        )
        var words = [
            WordEntry(id: "w_progeny", word: "progeny", definition: "Offspring; descendants of a person, animal, or plant.", explanation: "all the descendants of one pair", explanationProvider: "ChatGPT", lookups: [lookup]),
        ]
        let rendered = WordsDocument(frontMatter: matter, words: words).render()
        XCTAssertTrue(rendered.contains("In context (ChatGPT):"))
        XCTAssertTrue(rendered.contains("**progeny**"))
        let parsed = WordsDocument.parse(rendered)
        XCTAssertEqual(parsed.words.first?.word, "progeny")
        XCTAssertEqual(parsed.words.first?.lookups.first?.page, 63)
        XCTAssertEqual(parsed.words.first?.explanationProvider, "ChatGPT")
        XCTAssertEqual(parsed.words.first?.lookups.first?.sentence, lookup.sentence)

        let orphan = rendered + "\n- p. 62 · Ch. 3 · 2026-11-14 21:30 · looked up again\n"
        let withWarning = WordsDocument.parse(orphan)
        XCTAssertEqual(withWarning.words.first?.lookups.count, 1)
        XCTAssertTrue(withWarning.warnings.contains { $0.contains("no reader anchor") })

        let second = LookupEntry(id: "l2", page: 70, quote: "progeny", prefix: "", suffix: "", sentence: "progeny again", date: "2026-11-15T00:00:00Z")
        let undo = WordStore.record(words: &words, word: "Progeny", definition: "", explanation: nil, explanationProvider: nil, occurrence: second, id: "w_progeny")
        XCTAssertEqual(words.first?.count, 2)
        WordStore.undo(words: &words, undo)
        XCTAssertEqual(words.first?.lookups.map(\.id), ["l1"])

        var fresh: [WordEntry] = []
        let created = WordStore.record(words: &fresh, word: "economy", definition: "The orderly system.", explanation: nil, explanationProvider: nil, occurrence: second, id: "w_economy")
        XCTAssertEqual(fresh.count, 1)
        WordStore.undo(words: &fresh, created)
        XCTAssertTrue(fresh.isEmpty)
    }

    func testExportAllWordsMarkdownAndCSV() {
        let origin = ExportBook(title: "On the Origin of Species", words: [
            WordEntry(id: "w", word: "progeny", definition: "Offspring.", lookups: [
                LookupEntry(id: "l", page: 63, quote: "progeny", prefix: "the ", suffix: " of a pair", sentence: "the progeny of a pair", date: "2026-11-14"),
            ]),
            WordEntry(id: "e", word: "economy", definition: "The orderly system.", lookups: [
                LookupEntry(id: "l2", page: 62, quote: "economy", prefix: "the whole ", suffix: " of nature", sentence: "the whole economy of nature", date: "2026-11-14"),
            ]),
        ])
        let federalist = ExportBook(title: "Federalist No. 10", words: [
            WordEntry(id: "f", word: "faction", definition: "A small, organized group.", lookups: [
                LookupEntry(id: "l3", page: 2, quote: "faction", prefix: "By a ", suffix: ", I understand", sentence: "By a faction, I understand", date: "2026-11-15"),
            ]),
        ])
        let markdown = WordExport.markdown(books: [origin, federalist], date: "2026-11-15")
        XCTAssertTrue(markdown.hasPrefix("# All words · exported 2026-11-15 from 2 books"))
        let economy = markdown.range(of: "## economy")!
        let faction = markdown.range(of: "## faction")!
        let progeny = markdown.range(of: "## progeny")!
        XCTAssertLessThan(economy.lowerBound, faction.lowerBound)
        XCTAssertLessThan(faction.lowerBound, progeny.lowerBound)
        XCTAssertTrue(markdown.contains("On the Origin of Species · p. 62"))
        XCTAssertTrue(markdown.contains("Federalist No. 10 · p. 2"))
        let csv = WordExport.csv(books: [origin, federalist])
        XCTAssertTrue(csv.contains("word,definition,learned,book,location,section,sentence,date"))
        XCTAssertTrue(csv.contains("faction,\"A small, organized group.\""))
    }

    func testSentenceSpan() {
        let text = "We behold the face of nature. We often see superabundance of food; we do not see the cost."
        let span = SentenceSpan.sentence(containing: "superabundance", in: text)
        XCTAssertEqual(span?.sentence, "We often see superabundance of food; we do not see the cost.")
        XCTAssertEqual(span?.prefix, "We often see")
        XCTAssertTrue(span?.suffix.hasPrefix("of food") == true)
    }

    func testMarksRoundTripChordAndHistory() {
        var chord = MarkChord.idle
        var store = MarkStore()
        var history = NavigationHistory()
        let here = ReadingPosition(page: 63, scrollY: 0.42, zoom: 1.25, pdfX: 10, pdfY: 700, section: "Ch. 3", quote: "struggle")
        func key(_ character: String?, escape: Bool = false, command: Bool = false, focused: Bool = true, text: Bool = false) -> MarkKey {
            MarkKey(character: character, isEscape: escape, hasCommandModifier: command, documentFocused: focused, textInputFocused: text)
        }
        var ignored = MarkController.handle(chord: &chord, key: key("m", focused: false), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "id" })
        XCTAssertEqual(chord, .idle)
        XCTAssertTrue(store.local.isEmpty)
        ignored = MarkController.handle(chord: &chord, key: key("m", text: true), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "id" })
        XCTAssertNil(ignored.toast)

        let armed = MarkController.handle(chord: &chord, key: key("m"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "id" })
        XCTAssertEqual(chord, .awaitingSet)
        XCTAssertNil(armed.toast)
        let set = MarkController.handle(chord: &chord, key: key("a"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "m1" })
        XCTAssertEqual(set.toast, "Mark a set")
        XCTAssertEqual(store.local.map(\.symbol), ["a"])
        XCTAssertEqual(store.local.first?.position.scrollY, 0.42)
        XCTAssertEqual(store.local.first?.position.zoom, 1.25)

        let later = ReadingPosition(page: 70, scrollY: 0.1, zoom: 1)
        _ = MarkController.handle(chord: &chord, key: key("m"), store: &store, current: later, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t2", makeID: { "m2" })
        _ = MarkController.handle(chord: &chord, key: key("a"), store: &store, current: later, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t2", makeID: { "m2" })
        XCTAssertEqual(store.local.count, 1)
        XCTAssertEqual(store.local.first?.position.page, 70)

        _ = MarkController.handle(chord: &chord, key: key("m"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "g" })
        let global = MarkController.handle(chord: &chord, key: key("A"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "g" })
        XCTAssertEqual(global.toast, "Mark A set")
        XCTAssertEqual(store.global.map(\.symbol), ["A"])
        XCTAssertTrue(store.local.allSatisfy { $0.scope == .local })

        let elsewhere = ReadingPosition(page: 2, scrollY: 0)
        _ = MarkController.handle(chord: &chord, key: key("`"), store: &store, current: elsewhere, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "x" })
        XCTAssertEqual(chord, .awaitingJump)
        let arrived = MarkController.handle(chord: &chord, key: key("a"), store: &store, current: elsewhere, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "x" })
        XCTAssertEqual(arrived.toast, "Jumped to a")
        XCTAssertEqual(arrived.jump?.position.page, 70)
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.back(current: arrived.jump!.position)?.page, 2)

        let back = MarkController.handle(chord: &chord, key: key("`"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "x" })
        let toggled = MarkController.handle(chord: &chord, key: key("`"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "x" })
        XCTAssertEqual(toggled.toast, "Jumped back")
        XCTAssertEqual(toggled.jump?.position.page, elsewhere.page)
        _ = back

        _ = MarkController.handle(chord: &chord, key: key("m"), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "x" })
        let cancelled = MarkController.handle(chord: &chord, key: key(nil, escape: true), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "A", now: "t", makeID: { "x" })
        XCTAssertEqual(chord, .idle)
        XCTAssertTrue(cancelled.toast == nil)

        let matter = FrontMatter(kind: "marks", document: "Book.pdf", fingerprint: "sha256:a")
        let rendered = MarksDocument(frontMatter: matter, marks: store.local).render()
        let parsed = MarksDocument.parse(rendered)
        XCTAssertEqual(parsed.marks.first?.symbol, "a")
        XCTAssertEqual(parsed.marks.first?.position.scrollY, 0.1)
        XCTAssertEqual(parsed.marks.first?.position.zoom, 1)
        XCTAssertEqual(parsed.marks.first?.scope, .local)

        let directory = Paths.join(try! temporaryDirectory(), "support")
        let fs = LocalFileSystem()
        try! GlobalMarks.save(store.global, applicationSupport: directory, fs: fs)
        let loaded = GlobalMarks.load(applicationSupport: directory, fs: fs)
        XCTAssertEqual(loaded.map(\.symbol), ["A"])
        XCTAssertEqual(loaded.first?.bookPath, "/a.pdf")
        let localText = try! fs.readString(GlobalMarks.path(applicationSupport: directory))
        XCTAssertFalse(localText.contains("\"symbol\":\"a\""))
    }

    func testMarkListOrdersLinesAndQuestionMarkOpensTheList() {
        let here = ReadingPosition(page: 4, section: "Chapter 4", quote: "hard to vary\nmore")
        let local = MarkEntry(id: "m1", symbol: "b", position: here, documentTitle: "Book", setAt: "t")
        let earlier = MarkEntry(id: "m0", symbol: "a", position: ReadingPosition(page: 1, section: "Intro"), documentTitle: "Book", setAt: "t")
        let global = MarkEntry(id: "g1", symbol: "A", position: ReadingPosition(page: 9, quote: "global quote"), bookPath: "/other.pdf", documentTitle: "Other", setAt: "t")
        let lines = MarkList.lines(local: [local, earlier], global: [global])
        XCTAssertEqual(lines.map(\.symbol), ["a", "b", "A"])
        XCTAssertEqual(lines[0].location, "p. 1")
        XCTAssertEqual(lines[0].snippet, "Intro")
        XCTAssertEqual(lines[1].snippet, "hard to vary")
        XCTAssertEqual(lines[2].snippet, "Other — global quote")
        var store = MarkStore(local: [local], global: [global])
        XCTAssertTrue(store.remove(id: "m1"))
        XCTAssertTrue(store.local.isEmpty)
        XCTAssertEqual(store.global.map(\.id), ["g1"])
        var chord = MarkChord.idle
        var history = NavigationHistory()
        let opened = MarkController.handle(chord: &chord, key: MarkKey(character: "`", documentFocused: true, textInputFocused: false), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "Book", now: "t", makeID: { "x" })
        XCTAssertEqual(opened.effect, .consume)
        let listed = MarkController.handle(chord: &chord, key: MarkKey(character: "?", documentFocused: true, textInputFocused: false), store: &store, current: here, history: &history, bookFingerprint: "sha256:a", bookPath: "/a.pdf", title: "Book", now: "t", makeID: { "x" })
        XCTAssertEqual(listed.effect, .showList)
        XCTAssertEqual(chord, .idle)
    }

    func testSidecarCreateRenameMoveFallbackAndRelink() throws {
        let root = try temporaryDirectory()
        let fs = LocalFileSystem()
        let book = root + "/Origin.pdf"
        try fs.write(book, Data("pdf-bytes-v1".utf8))
        var index = LibraryIndex()
        let support = root + "/Application Support/Reader"
        let opened = try SidecarStore.open(bookPath: book, bookData: Data("pdf-bytes-v1".utf8), title: "Origin", index: &index, applicationSupport: support, fs: fs, now: "2026-11-16T00:00:00Z")
        XCTAssertEqual(opened.placement, .sibling)
        XCTAssertTrue(fs.isDirectory(root + "/Origin.reader"))
        XCTAssertTrue(fs.exists(root + "/Origin.reader/notes.md"))
        XCTAssertTrue(fs.exists(root + "/Origin.reader/words.md"))
        XCTAssertTrue(fs.exists(root + "/Origin.reader/highlights.md"))
        XCTAssertTrue(fs.exists(root + "/Origin.reader/marks.md"))
        XCTAssertEqual(index.documents.count, 1)

        var package = opened.package
        package.notes.notes = [NoteEntry(id: "n1", page: 3, quote: "natural selection", prefix: "called ", suffix: " works", section: "Ch. 4", body: "Remember this.")]
        try package.write(to: opened.directory, fs: fs)

        let renamedBook = root + "/Species.pdf"
        try fs.move(book, renamedBook)
        let afterRename = try SidecarStore.open(bookPath: renamedBook, bookData: Data("pdf-bytes-v1".utf8), title: "Species", index: &index, applicationSupport: support, fs: fs, now: "2026-11-16T00:01:00Z")
        XCTAssertEqual(afterRename.directory, root + "/Species.reader")
        XCTAssertEqual(afterRename.renamedFrom, root + "/Origin.reader")
        XCTAssertEqual(afterRename.package.notes.notes.first?.id, "n1")
        XCTAssertTrue(afterRename.notice?.contains("Renamed") == true)

        let elsewhere = root + "/shelf"
        try fs.createDirectory(elsewhere)
        let movedBook = elsewhere + "/Species.pdf"
        try fs.write(movedBook, Data("pdf-bytes-v1".utf8))
        let afterMove = try SidecarStore.open(bookPath: movedBook, bookData: Data("pdf-bytes-v1".utf8), title: "Species", index: &index, applicationSupport: support, fs: fs, now: "2026-11-16T00:02:00Z")
        XCTAssertEqual(afterMove.directory, root + "/Species.reader")
        XCTAssertEqual(afterMove.offerMoveTo, elsewhere + "/Species.reader")
        try SidecarStore.acceptMove(from: afterMove.directory, to: afterMove.offerMoveTo!, bookPath: movedBook, fingerprint: SHA256.fingerprint(Data("pdf-bytes-v1".utf8)), index: &index, fs: fs)
        XCTAssertTrue(fs.isDirectory(elsewhere + "/Species.reader"))
        XCTAssertEqual(index.documents.first?.sidecarPath, elsewhere + "/Species.reader")

        let memory = MemoryFileSystem()
        try memory.createDirectory("/books")
        try memory.createDirectory("/support")
        memory.readOnly.insert("/books")
        var memoryIndex = LibraryIndex()
        let fallback = try SidecarStore.open(bookPath: "/books/Locked.pdf", bookData: Data("locked".utf8), title: "Locked", index: &memoryIndex, applicationSupport: "/support", fs: memory, now: "t")
        XCTAssertEqual(fallback.placement, .applicationSupport)
        XCTAssertTrue(fallback.notice?.contains("Couldn't create") == true)
        XCTAssertTrue(memory.isDirectory(fallback.directory))

        let editionRoot = try temporaryDirectory()
        let editionFS = LocalFileSystem()
        let editionBook = editionRoot + "/Book.pdf"
        let original = Data("trailer /ID [<ABCD>] version-one".utf8)
        try editionFS.write(editionBook, original)
        var editionIndex = LibraryIndex()
        _ = try SidecarStore.open(bookPath: editionBook, bookData: original, title: "Book", index: &editionIndex, applicationSupport: editionRoot + "/support", fs: editionFS, now: "t")
        let edited = Data("trailer /ID [<ABCD>] version-two-small-edit".utf8)
        let relinked = try SidecarStore.open(bookPath: editionBook, bookData: edited, title: "Book", index: &editionIndex, applicationSupport: editionRoot + "/support", fs: editionFS, now: "t2")
        XCTAssertFalse(relinked.needsReanchor)
        XCTAssertEqual(relinked.package.notes.frontMatter.fingerprint, SHA256.fingerprint(edited))
        XCTAssertTrue(relinked.notice?.contains("small edit") == true)

        let replaced = Data("completely different book".utf8)
        let ask = try SidecarStore.open(bookPath: editionBook, bookData: replaced, title: "Book", index: &editionIndex, applicationSupport: editionRoot + "/support", fs: editionFS, now: "t3")
        XCTAssertTrue(ask.needsReanchor)
        XCTAssertTrue(ask.notice?.contains("quoted text") == true)
    }

    func testReanchorByQuote() {
        var package = SidecarPackage.empty(identity: FrontMatter(kind: "notes", document: "Book.pdf", fingerprint: "sha256:old"))
        package.notes.notes = [NoteEntry(id: "n1", page: 1, quote: "natural selection", prefix: "called ", suffix: " works slowly", body: "note")]
        package.highlights.highlights = [HighlightEntry(id: "h1", color: 4, page: 1, quote: "missing sentence", prefix: "", suffix: "")]
        let corpus = TextCorpus(slices: [
            TextSlice(page: 9, section: "Ch. 4", text: "This process, called natural selection works slowly over time."),
        ])
        let report = Reanchorer.apply(package: &package, corpus: corpus)
        XCTAssertEqual(package.notes.notes.first?.page, 9)
        XCTAssertEqual(package.notes.notes.first?.section, "Ch. 4")
        XCTAssertEqual(report.unresolvedIDs, ["h1"])
    }

    func testCFIZipAndEPUB() throws {
        let sample = "epubcfi(/6/14!/4/2/10,/1:0,/1:58)"
        let parsed = EPUBCFI(value: sample)
        XCTAssertEqual(parsed?.value, sample)
        XCTAssertEqual(parsed?.spineIndex, 6)
        XCTAssertEqual(parsed?.startOffset, 0)
        XCTAssertEqual(parsed?.endOffset, 58)
        let made = EPUBCFI.make(spineIndex: 0, start: 3, end: 9)
        XCTAssertEqual(made.value, "epubcfi(/6/2!/4,/1:3,/1:9)")
        XCTAssertEqual(EPUBCFI(value: made.value)?.spineIndex, 0)

        let payload = Data("hello epub payload".utf8)
        let stored = try ZipArchive.write([ZipEntry(name: "mimetype", data: Data("application/epub+zip".utf8)), ZipEntry(name: "a.txt", data: payload)], compressed: false)
        XCTAssertEqual(try ZipArchive.read(stored).first { $0.name == "a.txt" }?.data, payload)
        let deflated = try ZipArchive.write([ZipEntry(name: "mimetype", data: Data("application/epub+zip".utf8)), ZipEntry(name: "a.txt", data: payload)], compressed: true)
        XCTAssertEqual(try ZipArchive.read(deflated).first { $0.name == "a.txt" }?.data, payload)

        let epub = try sampleEPUB()
        let book = try EPUBBook(data: epub)
        XCTAssertEqual(book.title, "Sample Book")
        XCTAssertEqual(book.identifier, "urn:isbn:123")
        XCTAssertEqual(book.spine.first?.title, "Chapter 1")
        XCTAssertEqual(book.toc.first?.title, "Chapter 1")
        XCTAssertTrue(book.bookText().pages.first?.text.contains("superabundance") == true)
    }

    func testPromptWholeBookAndFallback() {
        let pages = [
            BookPage(marker: "p. 1", section: "Intro", text: "apples and oranges only here", page: 1),
            BookPage(marker: "p. 2", section: "Ch. 3", text: "the struggle for existence is sharpest within one species", page: 2),
            BookPage(marker: "p. 3", section: "Later", text: String(repeating: "filler word ", count: 400), page: 3),
        ]
        let book = BookText(title: "On the Origin of Species", pages: pages)
        let focus = Focus(quote: "within one species", page: 2, section: "Ch. 3")
        let whole = PromptAssembly.assemble(book: book, focus: focus, purpose: .ask("Why within one species?"), tokenBudget: 100_000)
        XCTAssertEqual(whole.contextMode, .wholeBook)
        XCTAssertTrue(whole.user.contains("<focus page=\"2\" section=\"Ch. 3\">"))
        XCTAssertTrue(whole.user.contains("[p. 1]"))
        XCTAssertTrue(whole.user.contains("[p. 3]"))
        XCTAssertTrue(whole.system.contains("Cite pages as (p. N)."))

        let partial = PromptAssembly.assemble(book: book, focus: focus, purpose: .ask("Why within one species?"), tokenBudget: 80)
        XCTAssertEqual(partial.contextMode, .chapterPlusPassages)
        XCTAssertTrue(partial.user.contains("partial=\"chapter-plus-passages\""))
        XCTAssertTrue(partial.user.contains("struggle for existence"))
        XCTAssertFalse(partial.user.contains("apples and oranges"))
        XCTAssertTrue(partial.system.contains("longer than the context window"))
    }

    func testProviderCommandsParseAndRouterSendsWithoutAsking() throws {
        let claude = ClaudeCommand.invocation(executable: "/opt/homebrew/bin/claude", prompt: "Answer", workingDirectory: "/tmp/job")
        XCTAssertEqual(claude.arguments, [
            "--print", "--verbose", "--output-format", "stream-json",
            "--permission-mode", "dontAsk",
            "--tools", "Read,Grep,Glob",
            "--allowedTools", "Read,Grep,Glob",
            "--", "Answer",
        ])
        XCTAssertFalse(claude.arguments.contains("--dangerously-skip-permissions"))
        let codex = CodexCommand.invocation(executable: "/opt/homebrew/bin/codex", prompt: "Answer", workingDirectory: "/tmp/job")
        XCTAssertEqual(codex.arguments, [
            "exec", "--sandbox", "read-only", "--ask-for-approval", "never",
            "--skip-git-repo-check", "--ephemeral", "--json", "-C", "/tmp/job", "Answer",
        ])
        XCTAssertFalse(codex.arguments.contains("--full-auto"))

        let claudeText = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Partial"}]}}
        {"type":"result","result":"Final answer","is_error":false}
        """
        XCTAssertEqual(try CLIOutput.parseClaude(claudeText), "Final answer")
        let codexText = """
        {"type":"thread.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"From the file."}}
        {"type":"turn.completed"}
        """
        XCTAssertEqual(try CLIOutput.parseCodex(codexText), "From the file.")

        let openAI = OpenAIProvider.request(apiKey: "sk-test", model: "gpt-4.1", system: "sys", user: "usr", stream: true)
        XCTAssertEqual(openAI.url, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAI.headers["Authorization"], "Bearer sk-test")
        let openBody = String(data: openAI.body, encoding: .utf8)!
        XCTAssertTrue(openBody.contains("\"model\":\"gpt-4.1\""))
        XCTAssertTrue(openBody.contains("\"stream\":true"))
        XCTAssertFalse(openBody.contains("confirm"))
        XCTAssertEqual(try OpenAIProvider.parse("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n"), "Hello")

        let anthropic = AnthropicProvider.request(apiKey: "ant", model: "claude-sonnet-4-5", system: "sys", user: "usr", stream: true)
        XCTAssertEqual(anthropic.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(anthropic.headers["x-api-key"], "ant")
        XCTAssertEqual(anthropic.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(try AnthropicProvider.parse("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n"), "Hi")

        XCTAssertEqual(AISettings.default.defaultProvider, .openai)
        XCTAssertFalse(AISettings.default.suggestedNotes)

        let transport = FakeTransport(body: "data: {\"choices\":[{\"delta\":{\"content\":\"Shared needs.\"}}]}\n\ndata: [DONE]\n")
        let runner = FakeRunner()
        let router = AIRouter(settings: .default, openAIKey: "sk-test", transport: transport, runner: runner)
        let book = BookText(title: "Origin", pages: [BookPage(marker: "p. 63", section: "Ch. 3", text: "struggle", page: 63)])
        let result = try sync {
            try await router.answer(book: book, focus: Focus(quote: "struggle", page: 63, section: "Ch. 3"), purpose: .ask("Why?"), cliDirectory: "/tmp", fs: LocalFileSystem())
        }
        XCTAssertEqual(result.text, "Shared needs.")
        XCTAssertEqual(result.contextMode, .wholeBook)
        XCTAssertTrue(result.providerLabel.contains("ChatGPT"))
        XCTAssertNotNil(transport.request)

        var settings = AISettings.default
        settings.defaultProvider = .claudeCLI
        settings.claudeCLIPath = "/opt/homebrew/bin/claude"
        let cliRouter = AIRouter(settings: settings, transport: transport, runner: runner)
        let directory = try temporaryDirectory()
        let cliResult = try sync {
            try await cliRouter.answer(book: book, focus: Focus(quote: "struggle", page: 63), purpose: .ask("Why?"), cliDirectory: directory, originalBookPath: nil, fs: LocalFileSystem())
        }
        XCTAssertEqual(cliResult.text, "Because they share the same food.")
        XCTAssertEqual(runner.invocation?.executable, "/opt/homebrew/bin/claude")
        XCTAssertTrue(runner.invocation?.arguments.contains("--print") == true)
        let focus = try LocalFileSystem().readString(directory + "/focus.md")
        XCTAssertTrue(focus.contains("struggle"))
        XCTAssertTrue(try LocalFileSystem().readString(directory + "/book.txt").contains("[p. 63]"))
    }

    func testProcessRunnerEchoTimeoutAndCancel() throws {
        let runner = ProcessCommandRunner()
        let echo = try runner.run(CLIInvocation(executable: "/bin/echo", arguments: ["hello"]), timeout: 5) { _ in }
        XCTAssertEqual(echo.stdout, "hello\n")
        XCTAssertEqual(echo.exitCode, 0)
        XCTAssertFalse(echo.timedOut)

        let slow = ProcessCommandRunner()
        let started = Date()
        let timed = try slow.run(CLIInvocation(executable: "/bin/sleep", arguments: ["5"]), timeout: 0.4) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(timed.timedOut || timed.exitCode != 0)

        let cancellable = ProcessCommandRunner()
        let queue = DispatchQueue(label: "cancel-test")
        let box = ResultBox<CommandResult>()
        let semaphore = DispatchSemaphore(value: 0)
        let cancelStarted = Date()
        queue.async {
            box.result = Result { try cancellable.run(CLIInvocation(executable: "/bin/sleep", arguments: ["5"]), timeout: 10) { _ in } }
            semaphore.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        cancellable.cancel()
        semaphore.wait()
        let cancelled = try box.result!.get()
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(cancelStarted), 2)
    }

    func testSettingsDefaultIsChatGPT() throws {
        let data = try JSONEncoder().encode(AISettings.default)
        let decoded = try JSONDecoder().decode(AISettings.self, from: data)
        XCTAssertEqual(decoded, .default)
        XCTAssertEqual(decoded.defaultProvider, .openai)
    }

    private func sampleEPUB() throws -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <package>
          <metadata>
            <dc:title>Sample Book</dc:title>
            <dc:identifier>urn:isbn:123</dc:identifier>
            <dc:creator>Ada</dc:creator>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """
        let nav = """
        <html><body><nav><ol><li><a href="c1.xhtml">Chapter 1</a></li></ol></nav></body></html>
        """
        let chapter = """
        <html><body><p>We often see superabundance of food.</p></body></html>
        """
        return try ZipArchive.write([
            ZipEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZipEntry(name: "META-INF/container.xml", data: Data(container.utf8)),
            ZipEntry(name: "OEBPS/content.opf", data: Data(opf.utf8)),
            ZipEntry(name: "OEBPS/nav.xhtml", data: Data(nav.utf8)),
            ZipEntry(name: "OEBPS/c1.xhtml", data: Data(chapter.utf8)),
        ], compressed: true)
    }
}
