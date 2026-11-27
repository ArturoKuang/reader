import XCTest
import Foundation
import ReaderCore
import ReaderSync

/// Live tests against the Mac mini loopback test server. Run with READER_SYNC_LIVE=1.
final class LiveIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["READER_SYNC_LIVE"] == "1",
            "Set READER_SYNC_LIVE=1 to run live tests against http://127.0.0.1:8789/v1/reader"
        )
    }

    func testLivePairRegisterUploadRoundTripConflictAndOffline() async throws {
        let configuration = SyncClientConfiguration(
            baseURL: SyncClientConfiguration.loopbackTestURL,
            loopbackLogin: "arturo@local",
            deviceName: "Live Test Mac",
            appVersion: "test"
        )
        // Health first so we fail clearly if 8789 is down.
        let probe = TailDriveAPI(http: SyncHTTPClient(configuration: configuration, transport: URLSessionSyncTransport()))
        let health = try await probe.health()
        XCTAssertTrue(health.ok)

        let macDir = FileManager.default.temporaryDirectory.appendingPathComponent("live-mac-\(UUID().uuidString)", isDirectory: true)
        let phoneDir = FileManager.default.temporaryDirectory.appendingPathComponent("live-phone-\(UUID().uuidString)", isDirectory: true)
        let macCreds = InMemoryCredentialStore()
        let phoneCreds = InMemoryCredentialStore()
        let mac = try SyncEngine(directory: macDir, configuration: configuration, credentials: macCreds)
        let phone = try SyncEngine(directory: phoneDir, configuration: configuration, credentials: phoneCreds)

        let macPair = try await mac.ensureMacPaired()
        XCTAssertEqual(macPair.kind, "mac")
        XCTAssertNotNil(macCreds.load(account: SyncKeychainAccount.credential))

        let phoneToken = try await mac.issuePhoneQR()
        let phoneQR = try PairingQR.parse(phoneToken.qr)
        XCTAssertEqual(phoneQR.version, 2)
        let phoneRedeem = try await phone.api.redeem(
            token: phoneQR.token,
            deviceId: phone.macDeviceId,
            name: "Live Test Phone",
            platform: "android",
            appVersion: "test"
        )
        try phoneCreds.save(account: SyncKeychainAccount.credential, secret: phoneRedeem.credential)
        try phoneCreds.save(account: SyncKeychainAccount.deviceId, secret: phoneRedeem.deviceId)
        try phoneCreds.save(account: SyncKeychainAccount.serverId, secret: phoneRedeem.serverId)
        phone.http.credential = phoneRedeem.credential
        XCTAssertEqual(phoneRedeem.kind, "phone")

        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fileData = Data("live-reader-sync-\(unique)".utf8)
        let bookURL = FileManager.default.temporaryDirectory.appendingPathComponent("LiveBook-\(unique).pdf")
        try fileData.write(to: bookURL)
        defer { try? FileManager.default.removeItem(at: bookURL) }

        let highlightId = "h_\(unique)"
        let macSnapshot = BookSyncSnapshot(
            fileURL: bookURL,
            fileData: fileData,
            format: "pdf",
            title: "Live Book \(unique)",
            docId: "live-\(unique)",
            highlights: [HighlightEntry(id: highlightId, color: 1, page: 1, quote: "live quote \(unique)", noteID: highlightId)],
            notes: [NoteEntry(id: highlightId, page: 1, quote: "live quote \(unique)", body: "mac first note")],
            words: [WordEntry(id: RecordAdapter.wordId(for: "liveword\(unique.prefix(6))"), word: "liveword\(unique.prefix(6))", definition: "a test word", lookups: [LookupEntry(id: "l_\(unique)", page: 1, quote: "liveword", sentence: "a liveword sentence", date: "2026-11-26")])],
            isPDF: true,
            page: 1,
            pdfPoint: (x: 1, y: 2),
            cfi: nil
        )

        try await mac.sync(snapshot: macSnapshot)

        // Deduped upload: HEAD should now be complete, second ingest must not fail.
        try await mac.ingest(macSnapshot)
        let head = try await mac.api.headBlob(sha256: macSnapshot.sha256)
        XCTAssertTrue(head.complete)

        try await phone.sync()
        let pulledNote = phone.store.record(bookId: "sha256:" + macSnapshot.sha256, kind: .note, recordId: highlightId)
            ?? phone.store.record(bookId: mac.store.bookId(forSha256: macSnapshot.sha256) ?? "", kind: .note, recordId: highlightId)
        // bookId may be sha256:<hex>
        let bookId = mac.store.bookId(forSha256: macSnapshot.sha256)
        XCTAssertNotNil(bookId)
        let phoneNote = phone.store.record(bookId: bookId ?? "", kind: .note, recordId: highlightId)
        XCTAssertNotNil(phoneNote, "phone should pull the Mac note")
        let phoneHighlight = phone.store.record(bookId: bookId ?? "", kind: .highlight, recordId: highlightId)
        XCTAssertNotNil(phoneHighlight)
        let phoneWord = phone.store.record(bookId: bookId ?? "", kind: .word, recordId: RecordAdapter.wordId(for: "liveword\(unique.prefix(6))"))
        XCTAssertNotNil(phoneWord)

        // Both-sides conflict: each device edits the note from the same base.
        let baseVersion = phoneNote?.serverVersion ?? 1
        func editNote(engine: SyncEngine, body: String) {
            let payload = RecordAdapter.notePayload(NoteEntry(id: highlightId, page: 1, quote: "live quote \(unique)", body: body), highlightId: highlightId)
            let data = try? JSONSupportBox.data(payload)
            engine.store.mergeOutbox(for: (bookId ?? "", .note, highlightId), into: OutboxItem(
                changeId: newChangeIdBox(),
                batchId: newBatchIdBox(),
                bookId: bookId ?? "",
                kind: .note,
                recordId: highlightId,
                baseVersion: baseVersion,
                deleted: false,
                payloadJSON: data,
                clientTime: ISO8601DateFormatter().string(from: Date())
            ))
            engine.store.upsertRecord(LocalRecordState(bookId: bookId ?? "", kind: .note, recordId: highlightId, serverVersion: baseVersion, dirty: true, deleted: false, payloadJSON: data))
        }
        editNote(engine: mac, body: "mac conflict body")
        editNote(engine: phone, body: "phone conflict body")
        try await mac.sync()
        try await phone.sync()
        try await mac.sync()
        let open = mac.conflicts() + phone.conflicts()
        XCTAssertFalse(open.isEmpty, "expected a keep-both conflict after both sides edited")

        if let conflict = (mac.conflicts() + phone.conflicts()).first(where: { $0.recordId == highlightId && $0.kind == .note }) {
            try await mac.resolve(conflict: conflict, choice: .combineNotes(body: "mac conflict body\nphone conflict body"))
            try await mac.sync()
            XCTAssertFalse(mac.conflicts().contains(where: { $0.conflictId == conflict.conflictId }))
        }

        // Offline edit + reconnect: queue while transport would fail, then push.
        let offlinePayload = RecordAdapter.notePayload(NoteEntry(id: highlightId, page: 1, quote: "live quote \(unique)", body: "offline edit"), highlightId: highlightId)
        let offlineData = try JSONSerialization.data(withJSONObject: offlinePayload)
        mac.store.mergeOutbox(for: (bookId ?? "", .note, highlightId), into: OutboxItem(
            changeId: "c_offline_\(unique)",
            batchId: "b_offline_\(unique)",
            bookId: bookId ?? "",
            kind: .note,
            recordId: highlightId,
            baseVersion: mac.store.record(bookId: bookId ?? "", kind: .note, recordId: highlightId)?.serverVersion ?? 1,
            deleted: false,
            payloadJSON: offlineData,
            clientTime: ISO8601DateFormatter().string(from: Date())
        ))
        mac.store.upsertRecord(LocalRecordState(bookId: bookId ?? "", kind: .note, recordId: highlightId, serverVersion: mac.store.record(bookId: bookId ?? "", kind: .note, recordId: highlightId)?.serverVersion ?? 1, dirty: true, deleted: false, payloadJSON: offlineData))
        try await mac.sync()
        try await phone.sync()
        let after = phone.store.record(bookId: bookId ?? "", kind: .note, recordId: highlightId)
        var body: String?
        if let data = after?.payloadJSON,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = object["body"] as? String
        }
        XCTAssertEqual(body, "offline edit")
    }
}

// Helpers visible to tests in this module. The production helpers are internal to ReaderSync.
private enum JSONSupportBox {
    static func data(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}

private func newChangeIdBox() -> String { "c_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
private func newBatchIdBox() -> String { "b_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
