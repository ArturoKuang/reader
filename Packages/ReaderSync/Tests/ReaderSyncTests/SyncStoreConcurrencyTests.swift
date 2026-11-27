import ReaderSync
import XCTest

final class SyncStoreConcurrencyTests: XCTestCase {
  func testConcurrentMetaAndRecordAccessDoesNotCrash() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reader-sync-store-stress-\(UUID().uuidString)", isDirectory: true)
    let store = try SyncStore(directory: directory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let workers = 16
    let iterations = 80
    await withTaskGroup(of: Void.self) { group in
      for worker in 0..<workers {
        group.addTask {
          for step in 0..<iterations {
            let key = "k\(worker % 8)"
            store.setMeta(key, "v-\(worker)-\(step)")
            _ = store.meta(key)
            store.cursor = step
            _ = store.cursor
            _ = store.deviceId
            store.deviceName = "Mac \(worker)"
            _ = store.deviceName
            store.storageFull = step.isMultiple(of: 7)
            _ = store.storageFull

            let record = LocalRecordState(
              bookId: "book-\(worker % 4)",
              kind: step.isMultiple(of: 2) ? .highlight : .note,
              recordId: "rec-\(worker)-\(step % 10)",
              serverVersion: step,
              dirty: true,
              deleted: false,
              payloadJSON: #"{"body":"w\#(worker)"}"#.data(using: .utf8)
            )
            store.upsertRecord(record)
            _ = store.record(bookId: record.bookId, kind: record.kind, recordId: record.recordId)
            if step.isMultiple(of: 5) {
              store.markClean(
                bookId: record.bookId, kind: record.kind, recordId: record.recordId, version: step)
            }

            let changeId = "chg-\(worker)-\(step)"
            store.enqueue(
              OutboxItem(
                changeId: changeId,
                batchId: "batch-\(worker)",
                bookId: record.bookId,
                kind: record.kind,
                recordId: record.recordId,
                baseVersion: step,
                deleted: false,
                payloadJSON: record.payloadJSON,
                clientTime: "2026-11-26T00:00:00Z"
              ))
            _ = store.outbox()
            if step.isMultiple(of: 11) {
              store.removeOutbox(changeIds: [changeId])
            }
          }
        }
      }
    }

    XCTAssertFalse(store.deviceId.isEmpty)
    XCTAssertNotNil(store.meta("k0") ?? store.meta("k1"))
    XCTAssertGreaterThanOrEqual(store.cursor, 0)
  }
}
