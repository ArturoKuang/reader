import XCTest
import ReaderCore
import ReaderSync

final class RecordAdapterTests: XCTestCase {
    func testWordIdIsDeterministic() {
        XCTAssertEqual(RecordAdapter.wordId(for: " Café "), "w_café")
        XCTAssertEqual(RecordAdapter.wordId(for: "ICE CREAM"), "w_ice cream")
        XCTAssertEqual(RecordAdapter.wordId(for: "Café"), RecordAdapter.wordId(for: "café"))
    }

    func testNoteIdReusesHighlightIdInPayload() {
        let highlight = HighlightEntry(id: "h_abc", color: 2, quote: "hello", noteID: "h_abc")
        let note = NoteEntry(id: "h_abc", quote: "hello", body: "a thought")
        let highlightPayload = RecordAdapter.highlightPayload(highlight)
        let notePayload = RecordAdapter.notePayload(note, highlightId: highlight.id)
        XCTAssertEqual(highlightPayload["noteId"] as? String, "h_abc")
        XCTAssertEqual(notePayload["highlightId"] as? String, "h_abc")
        XCTAssertEqual(note.id, highlight.id)
    }

    func testWordPayloadOmitsLookups() {
        let lookup = LookupEntry(id: "l_1", quote: "q", sentence: "s", date: "2026-11-26")
        let word = WordEntry(id: "w_test", word: "test", definition: "a trial", lookups: [lookup])
        let payload = RecordAdapter.wordPayload(word)
        XCTAssertNil(payload["lookups"])
        XCTAssertEqual(payload["word"] as? String, "test")
        let lookupPayload = RecordAdapter.lookupPayload(lookup, wordId: word.id)
        XCTAssertEqual(lookupPayload["wordId"] as? String, "w_test")
    }

    func testEPUBPositionIsChapterStartOnly() {
        let cfi = EPUBCFI.make(spineIndex: 2, start: 10, end: 20).value
        let payload = RecordAdapter.positionPayload(bookId: "sha256:ff", deviceId: "dev1", isPDF: false, page: nil, point: nil, cfi: cfi)
        let locator = payload["locator"] as? [String: Any]
        XCTAssertEqual(locator?["format"] as? String, "epub")
        XCTAssertEqual(locator?["cfi"] as? String, "epubcfi(/6/6!)")
        XCTAssertNil(locator?["progression"])
        XCTAssertTrue(EPUBPosition.sameChapter(cfi, "epubcfi(/6/6!)"))
        XCTAssertFalse(EPUBPosition.sameChapter(cfi, "epubcfi(/6/4!)"))
    }

    func testPDFPositionKeepsPageAndPoint() {
        let payload = RecordAdapter.positionPayload(bookId: "sha256:ff", deviceId: "dev1", isPDF: true, page: 12, point: (x: 10, y: 20), cfi: nil)
        let locator = payload["locator"] as? [String: Any]
        XCTAssertEqual(locator?["format"] as? String, "pdf")
        XCTAssertEqual(locator?["page"] as? Int, 12)
        let point = locator?["point"] as? [String: Any]
        XCTAssertEqual(point?["x"] as? Double, 10)
        XCTAssertEqual(point?["y"] as? Double, 20)
    }

    func testHighlightRoundTripRects() {
        let entry = HighlightEntry(id: "h_1", color: 3, page: 4, quote: "q", prefix: "p", suffix: "s", rects: [[1, 2, 3, 4]])
        let payload = RecordAdapter.highlightPayload(entry)
        let back = RecordAdapter.highlight(from: payload, id: "h_1")
        XCTAssertEqual(back.color, 3)
        XCTAssertEqual(back.page, 4)
        XCTAssertEqual(back.rects, [[1, 2, 3, 4]])
    }
}
