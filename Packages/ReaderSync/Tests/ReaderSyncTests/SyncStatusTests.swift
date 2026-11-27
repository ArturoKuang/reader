import XCTest
import ReaderSync

final class SyncStatusTests: XCTestCase {
    func testPriorityOrderMatchesTokensV2() {
        XCTAssertEqual(SyncChipState.priority, [.error, .storageFull, .conflict, .offline, .syncing, .synced])
        XCTAssertEqual(
            SyncChipState.resolve(unreachable: true, storageFull: true, conflictCount: 2, offline: true, syncing: true),
            .error
        )
        XCTAssertEqual(
            SyncChipState.resolve(unreachable: false, storageFull: true, conflictCount: 2, offline: true, syncing: true),
            .storageFull
        )
        XCTAssertEqual(
            SyncChipState.resolve(unreachable: false, storageFull: false, conflictCount: 2, offline: true, syncing: true),
            .conflict
        )
        XCTAssertEqual(
            SyncChipState.resolve(unreachable: false, storageFull: false, conflictCount: 0, offline: true, syncing: true),
            .offline
        )
        XCTAssertEqual(
            SyncChipState.resolve(unreachable: false, storageFull: false, conflictCount: 0, offline: false, syncing: true),
            .syncing
        )
        XCTAssertEqual(
            SyncChipState.resolve(unreachable: false, storageFull: false, conflictCount: 0, offline: false, syncing: false),
            .synced
        )
    }

    func testLabelsAndActions() {
        XCTAssertEqual(SyncChipState.storageFull.dotHex, "EB5757")
        XCTAssertEqual(SyncChipState.storageFull.label(), "Mac mini is full")
        XCTAssertEqual(SyncChipState.storageFull.detail, "Books paused. Highlights and notes still sync.")
        XCTAssertEqual(SyncChipState.storageFull.action, "Check again")
        XCTAssertEqual(SyncChipState.storageFull.bookBadge, "Waiting for space")
        XCTAssertEqual(SyncChipState.error.label(), "Can't reach Mac mini")
        XCTAssertEqual(SyncChipState.error.action, "Retry")
        XCTAssertEqual(SyncChipState.conflict.label(conflictCount: 2), "2 versions to review")
        XCTAssertEqual(SyncChipState.conflict.label(conflictCount: 1), "1 version to review")
        XCTAssertEqual(SyncChipState.conflict.dotHex, "F2994A")
        XCTAssertEqual(SyncChipState.synced.dotHex, "27AE60")
        XCTAssertTrue(SyncChipState.syncing.animates)
        XCTAssertFalse(SyncChipState.storageFull.animates)
    }
}
