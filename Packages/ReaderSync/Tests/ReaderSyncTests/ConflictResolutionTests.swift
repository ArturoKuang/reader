import XCTest
import ReaderSync

final class ConflictResolutionTests: XCTestCase {
    let macId = "mac-1"
    let phoneId = "phone-1"

    func sampleConflict(kind: RecordKind = .note) -> OpenConflict {
        OpenConflict(
            conflictId: "cf_1",
            bookId: "sha256:abc",
            kind: kind,
            recordId: "h_1",
            baseVersion: 3,
            baseDeleted: false,
            basePayload: ["body": "base", "extras": [:]],
            sides: [
                ConflictSide(changeId: "c_mac", deviceId: macId, version: 4, deleted: false, payload: ["body": "Mac note", "color": 1, "quote": "Detecting concurrent writes", "prefix": "", "suffix": "", "ai": false, "scope": "passage", "extras": [:]], clientTime: "2026-11-26T20:42:00Z"),
                ConflictSide(changeId: "c_phone", deviceId: phoneId, version: nil, deleted: false, payload: ["body": "Phone note", "color": 3, "quote": "Detecting concurrent writes", "prefix": "", "suffix": "", "ai": false, "scope": "passage", "extras": [:]], clientTime: "2026-11-26T20:47:00Z"),
            ],
            openedSeq: 10
        )
    }

    func testKeepMacVersion() throws {
        let prepared = try ConflictResolution.prepare(conflict: sampleConflict(), choice: .keepSide(0), macDeviceIds: [macId])
        XCTAssertEqual(prepared.request.baseVersion, 4)
        XCTAssertEqual(prepared.request.deleted, false)
        XCTAssertEqual(prepared.request.payload?["body"] as? String, "Mac note")
        XCTAssertEqual(prepared.note?.body, "Mac note")
        XCTAssertEqual(prepared.conflictId, "cf_1")
    }

    func testKeepPhoneVersion() throws {
        let prepared = try ConflictResolution.prepare(conflict: sampleConflict(), choice: .keepSide(1), macDeviceIds: [macId])
        XCTAssertEqual(prepared.request.payload?["body"] as? String, "Phone note")
        XCTAssertEqual(prepared.note?.body, "Phone note")
    }

    func testCombineNotesKeepsMacColor() throws {
        let conflict = sampleConflict(kind: .highlight)
        let prepared = try ConflictResolution.prepare(
            conflict: conflict,
            choice: .combineNotes(body: "Mac note\nPhone note"),
            macDeviceIds: [macId]
        )
        XCTAssertEqual(prepared.request.payload?["body"] as? String, "Mac note\nPhone note")
        XCTAssertEqual(prepared.request.payload?["color"] as? Int, 1, "combined note saves with Mac highlight color")
        XCTAssertFalse(prepared.request.deleted)
    }

    func testDefaultCombinedBodyJoinsBothSides() {
        let body = ConflictResolution.defaultCombinedBody(conflict: sampleConflict(), macDeviceIds: [macId])
        XCTAssertEqual(body, "Mac note\nPhone note")
    }

    func testDeletedSideIsPreservedWhenKept() throws {
        var conflict = sampleConflict()
        conflict.sides[1] = ConflictSide(changeId: "c_phone", deviceId: phoneId, version: nil, deleted: true, payload: nil, clientTime: nil)
        let prepared = try ConflictResolution.prepare(conflict: conflict, choice: .keepSide(1), macDeviceIds: [macId])
        XCTAssertTrue(prepared.request.deleted)
        XCTAssertNil(prepared.note)
    }
}
