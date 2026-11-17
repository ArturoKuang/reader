import Foundation
import ReaderCore
import XCTest

final class VaultTests: XCTestCase {
    func testVaultDetectionStopsAtObsidianFolder() throws {
        let fs = MemoryFileSystem()
        try fs.createDirectory("/Users/arturokuang/Downloads/SecondBrain/.obsidian")
        try fs.createDirectory("/Users/arturokuang/Downloads/SecondBrain/books/beginning-of-infinity")
        try fs.write("/Users/arturokuang/Downloads/SecondBrain/books/beginning-of-infinity/book.epub", Data("epub".utf8))
        let found = VaultFinder.locate(bookPath: "/Users/arturokuang/Downloads/SecondBrain/books/beginning-of-infinity/book.epub", fs: fs)
        XCTAssertEqual(found?.vaultName, "SecondBrain")
        XCTAssertEqual(found?.bookFolder, "/Users/arturokuang/Downloads/SecondBrain/books/beginning-of-infinity")
        XCTAssertNil(VaultFinder.locate(bookPath: "/tmp/loose/book.pdf", fs: fs))
    }

    func testOwnedBlocksPreserveFreeformText() {
        let original = "freeform outline\n\t- a typo here\n\t- still mine\n"
        let added = OwnedBlocks.upsert(original, id: "n1", body: "Reader note")
        XCTAssertTrue(added.hasPrefix(original))
        XCTAssertEqual(OwnedBlocks.body(id: "n1", in: added), "Reader note")
        let edited = OwnedBlocks.upsert(added, id: "n1", body: "Rewritten")
        XCTAssertTrue(edited.hasPrefix(original))
        XCTAssertEqual(OwnedBlocks.body(id: "n1", in: edited), "Rewritten")
        XCTAssertFalse(edited.contains("Reader note\n"))
        let removed = OwnedBlocks.remove(edited, id: "n1")
        XCTAssertTrue(removed.hasPrefix(original))
        XCTAssertEqual(removed.trimmingCharacters(in: .whitespacesAndNewlines), original.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(removed.contains("reader:begin"))
    }

    func testVocabularyInsertsUnderChapterWithoutReordering() {
        let hand = """
        # Vocabulary — Beginning of Infinity

        ## Chapter 3

        ### already
        - **Meaning:** handwritten
        - **Book context:** “old”
        - **Added:** October 1, 2026

        ## Chapter 5

        ### later
        - **Meaning:** stays put
        - **Added:** October 2, 2026
        """
        let entry = VocabEntry(id: "w1", word: "progeny", chapter: 4, meaning: "Offspring.", bookContext: "the progeny of a pair", plainLanguage: nil, example: nil, added: LongDate.format(year: 2026, month: 10, day: 13), readerOwned: true)
        let updated = VocabularyFile.upsert(hand, title: "Beginning of Infinity", entry: entry)
        XCTAssertTrue(updated.contains("### already"))
        XCTAssertTrue(updated.contains("### later"))
        let chapter4 = updated.range(of: "## Chapter 4")!
        let chapter5 = updated.range(of: "## Chapter 5")!
        let chapter3 = updated.range(of: "## Chapter 3")!
        XCTAssertLessThan(chapter3.lowerBound, chapter4.lowerBound)
        XCTAssertLessThan(chapter4.lowerBound, chapter5.lowerBound)
        XCTAssertTrue(updated.contains("- **Meaning:** Offspring"))
        XCTAssertTrue(updated.contains("### Progeny"))
        XCTAssertTrue(updated.contains("- **Book context:** “the progeny of a pair”"))
        XCTAssertTrue(updated.contains("- **Added:** October 13, 2026"))
        XCTAssertFalse(updated.contains("In plain language"))
        XCTAssertFalse(updated.contains("**Example:**"))
        let parsed = VocabularyFile.parse(updated)
        XCTAssertEqual(parsed.first { $0.word == "already" }?.meaning, "handwritten")
        XCTAssertEqual(parsed.first { $0.word == "already" }?.readerOwned, false)
        XCTAssertEqual(parsed.first { $0.id == "w1" }?.chapter, 4)
        XCTAssertEqual(parsed.first { $0.id == "w1" }?.readerOwned, true)
    }

    func testRewritingANoteKeepsEarlierBlockLocations() {
        let path = "/books/beginning-of-infinity/book.epub"
        let firstLocation = "epubcfi(/6/8!/4,/1:89,/1:130)"
        let newest = "epubcfi(/6/10!/4,/1:211,/1:222)"
        let first = VaultNoteBlock(
            id: "h1",
            quote: "hard to vary",
            body: "",
            color: 1,
            link: ReaderLink(path: path, location: firstLocation, id: "h1")
        )
        let original = VaultNoteFile.upsert("", block: first)
        let stamped = VaultNoteBlock(
            id: "h1",
            quote: "hard to vary",
            body: "",
            color: 1,
            link: ReaderLink(path: path, location: newest, id: "h1")
        )
        let added = VaultNoteBlock(
            id: "h2",
            quote: "a later passage",
            body: "note",
            link: ReaderLink(path: path, location: newest, id: "h2")
        )
        let updated = VaultNoteFile.upsertPreservingLocations(original, blocks: [stamped, added])
        let blocks = VaultNoteFile.blocks(updated)
        XCTAssertEqual(blocks.first { $0.id == "h1" }?.quote, "hard to vary")
        XCTAssertEqual(blocks.first { $0.id == "h1" }?.link.location, firstLocation)
        XCTAssertFalse(blocks.first { $0.id == "h1" }?.link.url.contains("1:211") ?? true)
        XCTAssertEqual(blocks.first { $0.id == "h2" }?.link.location, newest)
    }

    func testHighlightAndNoteBlocksRoundTripLinks() {
        let link = ReaderLink(path: "/Users/arturokuang/Downloads/SecondBrain/books/beginning-of-infinity/book.epub", location: "epubcfi(/6/4!/4,/1:0,/1:12)", id: "h1")
        let block = VaultNoteBlock(id: "h1", quote: "hard to vary", body: "A note of mine.", color: 1, link: link, chapter: 4)
        let file = VaultNoteFile.upsert("Arturo's outline\n\t- typo\n", block: block)
        XCTAssertTrue(file.hasPrefix("Arturo's outline\n\t- typo\n"))
        XCTAssertTrue(file.contains("> [!quote] yellow"))
        XCTAssertTrue(file.contains("> hard to vary"))
        XCTAssertTrue(file.contains("[↗ Open in Reader](reader://open?"))
        XCTAssertTrue(file.contains("^h1"))
        let parsed = VaultNoteFile.blocks(file)
        XCTAssertEqual(parsed.first?.quote, "hard to vary")
        XCTAssertEqual(parsed.first?.color, 1)
        XCTAssertEqual(parsed.first?.body, "A note of mine.")
        XCTAssertEqual(parsed.first?.link.path, link.path)
        let again = ReaderLink.parse(parsed.first?.link.url ?? "")
        XCTAssertEqual(again?.location, link.location)
        let obsidian = ObsidianLink.open(vault: "SecondBrain", file: "books/beginning-of-infinity/notes/Chapter 4.md", blockID: "h1")
        XCTAssertTrue(obsidian.hasPrefix("obsidian://open?vault=SecondBrain&file="))
        XCTAssertTrue(obsidian.contains("%23%5Eh1") || obsidian.contains("#^h1") || obsidian.contains("%5Eh1"))
    }

    func testConceptsMasteryAndTutorEvent() throws {
        let source = """
        ## Ch 4 · Explanations

        - ★ **C1.7 · Good explanations are hard to vary** · pre: C1.2, C1.5 · find: `Persephone`, `hard to vary`, `tilt`
          - **Claim:** An explanation that survives variation is good.
          - **Trap:** A prophecy can be made unfalsifiable.
        - **B4 · Background primer** · find: `primer`
        - **C1.7b · A variant** · pre: C1.7 · find: `variant`
        """
        let concepts = ConceptsFile.parse(source)
        XCTAssertEqual(concepts.map(\.id), ["C1.7", "B4", "C1.7b"])
        XCTAssertEqual(concepts[0].chapter, 4)
        XCTAssertEqual(concepts[0].prerequisites, ["C1.2", "C1.5"])
        XCTAssertEqual(concepts[0].findTerms, ["Persephone", "hard to vary", "tilt"])
        XCTAssertEqual(concepts[0].claim, "An explanation that survives variation is good.")
        XCTAssertTrue(concepts[0].wiki.contains("[[C1.7 Good explanations"))
        let suggested = ConceptsFile.suggested(passage: "That account is hard to vary.", concepts: concepts, chapter: 4)
        XCTAssertEqual(suggested.map(\.id), ["C1.7"])
        XCTAssertEqual(ConceptsFile.autocomplete(prefix: "c1.7b", concepts: concepts).map(\.id), ["C1.7b"])
        let stub = ConceptsFile.stub(for: concepts[0])
        XCTAssertTrue(stub.contains("**Claim:**"))
        let mastery = MasteryFile.parse("{\"C1.7\":{\"status\":\"learning\",\"box\":2,\"next_review\":\"2026-12-01\"},\"B4\":\"known\"}")
        XCTAssertEqual(MasteryFile.badge(mastery["C1.7"]), .due)
        XCTAssertEqual(MasteryFile.badge(mastery["B4"]), .known)
        XCTAssertEqual(MasteryFile.badge(nil), .notStarted)
        let event = TutorExchange(bookID: "beginning-of-infinity", chapter: 4, conceptIDs: ["C1.7"], passageCharacterCount: 42, date: "2026-10-13", eventID: "reader-abc")
        let line = event.jsonLine()
        XCTAssertFalse(line.contains("passage\""))
        XCTAssertTrue(line.contains("\"passage_chars\":42"))
        XCTAssertTrue(line.contains("\"type\":\"reader_passage_question\""))
        XCTAssertTrue(line.contains("\"source\":\"reader_app\""))
        let json = try XCTUnwrap(JSONValue.parse(line))
        XCTAssertEqual(json["book_id"]?.string, "beginning-of-infinity")
        XCTAssertNil(json["passage"])
        let tutor = ClaudeCommand.tutorInvocation(executable: "/opt/homebrew/bin/claude", prompt: "Ask one question.", workingDirectory: "/vault/book", sessionID: "sess-1")
        XCTAssertEqual(tutor.workingDirectory, "/vault/book")
        XCTAssertTrue(tutor.arguments.contains("--resume"))
        XCTAssertTrue(tutor.arguments.contains("sess-1"))
        XCTAssertFalse(tutor.arguments.contains("--ephemeral"))
        XCTAssertTrue(tutor.arguments.contains("--continue") == false)
        XCTAssertTrue(ClaudeCommand.tutorWriteTools.contains("Write(learner/**)"))
        let fresh = ClaudeCommand.tutorInvocation(executable: "claude", prompt: "Hi", workingDirectory: "/book", sessionID: nil)
        XCTAssertFalse(fresh.arguments.contains("--continue"))
        let prompt = TutorPrompt.message(passage: "hard to vary", chapter: 4, chapterFile: "book/04.md", concepts: [concepts[0]], question: "Why?", command: .learn)
        XCTAssertTrue(prompt.contains("/learn"))
        XCTAssertTrue(prompt.contains("one question at a time"))
        XCTAssertTrue(prompt.contains("C1.7"))
    }

    func testExternalEditMergesByBlockAndKeepsConflicts() {
        let original = "mine\n"
        let first = OwnedBlocks.upsert(original, id: "n1", body: "v1")
        var state = VaultSyncState(disk: first, pending: ["n1": "v1"], written: ["n1": "v1"])
        let outside = OwnedBlocks.upsert(original, id: "n1", body: "from obsidian")
        let adopted = VaultSync.applyExternal(state, disk: outside)
        XCTAssertTrue(adopted.conflicts.isEmpty)
        XCTAssertEqual(OwnedBlocks.body(id: "n1", in: adopted.state.disk), "from obsidian")
        state.pending["n1"] = "typing in reader"
        let clash = VaultSync.applyExternal(state, disk: outside)
        XCTAssertEqual(clash.conflicts, ["n1"])
        XCTAssertTrue(clash.state.disk.contains("typing in reader"))
        XCTAssertTrue(clash.state.disk.contains("from obsidian"))
        XCTAssertTrue(clash.state.disk.hasPrefix("mine\n"))
        XCTAssertTrue(VaultSync.isOwnWrite(newDisk: first, lastWritten: first))
    }

    func testTutorSendsTheQuestionAndStartsAFreshSession() {
        let prompt = TutorPrompt.message(passage: "hard to vary", chapter: 4, chapterFile: "book/04-explanations.md", concepts: [], question: "Why is this hard?", command: .learn)
        XCTAssertTrue(prompt.hasPrefix("/learn Why is this hard?"))
        XCTAssertTrue(prompt.contains("hard to vary"))
        let fresh = ClaudeCommand.tutorInvocation(executable: "claude", prompt: prompt, workingDirectory: "/book", sessionID: nil)
        XCTAssertFalse(fresh.arguments.contains("--continue"))
        XCTAssertFalse(fresh.arguments.contains("--resume"))
        let resumed = ClaudeCommand.tutorInvocation(executable: "claude", prompt: prompt, workingDirectory: "/book", sessionID: "sess-9")
        XCTAssertEqual(Array(resumed.arguments.drop(while: { $0 != "--resume" }).prefix(2)), ["--resume", "sess-9"])
        XCTAssertFalse(resumed.arguments.contains("--continue"))
        let home = "/Users/arturokuang"
        XCTAssertEqual(
            ClaudeExecutable.resolve(override: "/custom/claude", home: home, fileExists: { _ in false }, loginShellPath: { nil }),
            "/custom/claude"
        )
        XCTAssertEqual(
            ClaudeExecutable.resolve(override: "  ", home: home, fileExists: { $0.hasSuffix("/.local/bin/claude") }, loginShellPath: { "/opt/homebrew/bin/claude" }),
            home + "/.local/bin/claude"
        )
        XCTAssertEqual(
            ClaudeExecutable.resolve(override: nil, home: home, fileExists: { $0 == "/opt/homebrew/bin/claude" }, loginShellPath: { "/opt/homebrew/bin/claude" }),
            "/opt/homebrew/bin/claude"
        )
    }

    func testClaudeSessionIDIsReadFromStreamJSON() {
        let stdout = """
        {"type":"assistant","session_id":"sess-9","message":{"content":[{"type":"text","text":"Why?"}]}}
        {"type":"result","session_id":"sess-9","result":"Why?"}
        """
        XCTAssertEqual(CLIOutput.claudeSessionID(stdout), "sess-9")
        XCTAssertEqual(try CLIOutput.parseClaude(stdout), "Why?")
        let link = ReaderLink(path: "/book.pdf", location: "page=4&y=12", id: "h1")
        XCTAssertEqual(ReaderLink.parse(link.url)?.pageNumber, 4)
    }

    func testChapterTextFileNames() throws {
        let fs = MemoryFileSystem()
        try fs.createDirectory("/book/book")
        try fs.write("/book/book/00-introduction.md", Data("intro".utf8))
        try fs.write("/book/book/04-explanations.md", Data("ch".utf8))
        XCTAssertEqual(ChapterFiles.chapterTextFile(bookFolder: "/book", chapter: 0, fs: fs), "book/00-introduction.md")
        XCTAssertEqual(ChapterFiles.chapterTextFile(bookFolder: "/book", chapter: 4, fs: fs), "book/04-explanations.md")
        XCTAssertEqual(ChapterFiles.notesFile(chapter: 4, bookTitle: "Ignored"), "Chapter 4.md")
        XCTAssertEqual(ChapterFiles.number(in: "Chapter 4 · Explanations"), 4)
        XCTAssertEqual(ChapterFiles.number(in: "Introduction"), 0)
        let spine = [
            EPUBSpineItem(id: "cover", href: "cover.xhtml", mediaType: "application/xhtml+xml", title: "cover.xhtml"),
            EPUBSpineItem(id: "intro", href: "text/intro.xhtml", mediaType: "application/xhtml+xml", title: "intro.xhtml"),
            EPUBSpineItem(id: "c1", href: "text/ch01.xhtml", mediaType: "application/xhtml+xml", title: "ch01.xhtml"),
            EPUBSpineItem(id: "c1b", href: "text/ch01b.xhtml", mediaType: "application/xhtml+xml", title: "ch01b.xhtml"),
            EPUBSpineItem(id: "c18", href: "text/ch18.xhtml", mediaType: "application/xhtml+xml", title: "ch18.xhtml"),
        ]
        let toc = [
            EPUBTOCItem(title: "Cover", href: "cover.xhtml", depth: 0),
            EPUBTOCItem(title: "Introduction", href: "text/intro.xhtml", depth: 0),
            EPUBTOCItem(title: "Chapter 1. The Reach of Explanations", href: "text/ch01.xhtml#start", depth: 0),
            EPUBTOCItem(title: "Chapter 18. The Beginning", href: "text/ch18.xhtml", depth: 0),
        ]
        let placed = SpineChapters.placements(spine: spine, toc: toc)
        XCTAssertEqual(placed.map(\.chapter), [nil, 0, 1, 1, 18])
        XCTAssertFalse(ConceptMatching.contains(term: "219", in: "postcode SW1A 2190"))
        XCTAssertTrue(ConceptMatching.contains(term: "219", in: "postcode 219"))
        XCTAssertFalse(ConceptMatching.contains(term: "aerodynamic", in: "aerodynamics"))
        XCTAssertTrue(ConceptMatching.contains(term: "aerodynamic", in: "an aerodynamic tilt"))
        XCTAssertEqual(VocabularyFile.heading("progeny"), "Progeny")
        XCTAssertEqual(VocabularyFile.shortMeaning("noun\n1. Offspring; descendants of a person.\n2. Outcome."), "Offspring")
        XCTAssertEqual(placed[2].title, "Chapter 1. The Reach of Explanations")
        XCTAssertEqual(ChapterFiles.notesFile(chapter: placed[2].chapter, bookTitle: "book.epub"), "Chapter 1.md")
    }
}
