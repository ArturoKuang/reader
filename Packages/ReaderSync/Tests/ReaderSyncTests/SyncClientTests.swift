import XCTest
import ReaderCore
import ReaderSync

final class SyncClientTests: XCTestCase {
    func testPairingIssuesQRAndStoresCredential() async throws {
        let transport = MockTransport()
        transport.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/pairing/tokens") {
                XCTAssertEqual((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["kind"] as? String, "mac")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Tailscale-User-Login"), "arturo@local")
                return jsonResponse(200, [
                    "token": "MACTOKEN",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "qr": "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=MACTOKEN&server=srv_test",
                ])
            }
            if path.hasSuffix("/v1/pairing/redeem") {
                return jsonResponse(200, ["deviceId": "dev-mac", "credential": "secret-cred", "serverId": "srv_test", "kind": "mac"])
            }
            return jsonResponse(404, [:])
        }
        let (engine, credentials, _) = try makeEngine(transport: transport)
        let redeemed = try await engine.ensureMacPaired()
        XCTAssertEqual(redeemed.kind, "mac")
        XCTAssertEqual(credentials.load(account: SyncKeychainAccount.credential), "secret-cred")
        XCTAssertEqual(engine.http.credential, "secret-cred")
    }

    func testPhoneQRUsesV2() async throws {
        let transport = MockTransport()
        var kinds: [String] = []
        transport.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/pairing/tokens") {
                let kind = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["kind"] as? String ?? ""
                kinds.append(kind)
                return jsonResponse(200, [
                    "token": kind.uppercased() + "TOK",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "qr": "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=\(kind.uppercased())TOK&server=srv_test",
                ])
            }
            if path.hasSuffix("/v1/pairing/redeem") {
                return jsonResponse(200, ["deviceId": "dev-mac", "credential": "secret-cred", "serverId": "srv_test", "kind": "mac"])
            }
            return jsonResponse(404, [:])
        }
        let (engine, _, _) = try makeEngine(transport: transport)
        let issued = try await engine.issuePhoneQR()
        XCTAssertEqual(kinds, ["mac", "phone"])
        let qr = try PairingQR.parse(issued.qr)
        XCTAssertEqual(qr.version, 2)
        XCTAssertEqual(qr.token, "PHONETOK")
    }

    func testUnreachableSetsErrorState() async throws {
        let transport = MockTransport()
        transport.handler = { _ in
            throw SyncAPIError.network("offline")
        }
        let (engine, credentials, _) = try makeEngine(transport: transport)
        try credentials.save(account: SyncKeychainAccount.credential, secret: "cred")
        engine.http.credential = "cred"
        do {
            try await engine.sync()
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(engine.status().state, .error)
            XCTAssertEqual(engine.status().label, "Can't reach Mac mini")
        }
    }

    func testDeletingLocalNoteEnqueuesTombstoneAndDoesNotResurrect() async throws {
        let transport = MockTransport()
        var pushedChanges: [[String: Any]] = []
        transport.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/books") {
                return jsonResponse(200, ["bookId": "book-1", "duplicate": false])
            }
            if path.contains("/v1/blobs/"), request.httpMethod == "HEAD" {
                return SyncHTTPResponse(status: 200, headers: ["Upload-Offset": "10", "Upload-Complete": "true"], data: Data())
            }
            if path.hasSuffix("/v1/changes"), request.httpMethod == "POST" {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
                let changes = body["changes"] as? [[String: Any]] ?? []
                pushedChanges.append(contentsOf: changes)
                let results: [[String: Any]] = changes.enumerated().map { idx, change in
                    [
                        "changeId": change["changeId"] as? String ?? "c\(idx)",
                        "status": "applied",
                        "version": (change["baseVersion"] as? Int ?? 0) + 1,
                    ]
                }
                return jsonResponse(200, ["results": results])
            }
            if path.hasSuffix("/v1/health") {
                return jsonResponse(200, ["serverId": "srv_test", "ok": true])
            }
            if path.hasSuffix("/v1/changes"), request.httpMethod == "GET" {
                return jsonResponse(200, ["serverId": "srv_test", "cursor": 1, "hasMore": false, "changes": []])
            }
            if path.hasSuffix("/v1/conflicts") {
                return jsonResponse(200, ["conflicts": []])
            }
            if path.hasSuffix("/v1/devices") {
                return jsonResponse(200, ["devices": []])
            }
            return jsonResponse(404, [:])
        }

        let (engine, credentials, _) = try makeEngine(transport: transport)
        try credentials.save(account: SyncKeychainAccount.credential, secret: "cred")
        engine.http.credential = "cred"

        let data = Data("sample-pdf".utf8)
        let url = URL(fileURLWithPath: "/tmp/sample.pdf")
        let highlight = HighlightEntry(id: "h1", color: 1, page: 4, quote: "hello", noteID: "h1")
        let note = NoteEntry(id: "h1", page: 4, quote: "hello", body: "my note")

        let first = BookSyncSnapshot(
            fileURL: url,
            fileData: data,
            format: "pdf",
            title: "Sample",
            docId: nil,
            highlights: [highlight],
            notes: [note],
            words: [],
            isPDF: true,
            page: 4,
            pdfPoint: nil,
            cfi: nil
        )
        try await engine.sync(snapshot: first)
        pushedChanges.removeAll()

        // Delete the highlight & note locally, then sync again.
        let afterDelete = BookSyncSnapshot(
            fileURL: url,
            fileData: data,
            format: "pdf",
            title: "Sample",
            docId: nil,
            highlights: [],
            notes: [],
            words: [],
            isPDF: true,
            page: 4,
            pdfPoint: nil,
            cfi: nil
        )
        try await engine.sync(snapshot: afterDelete)

        let deletedKinds = Set(pushedChanges.filter { ($0["deleted"] as? Bool) == true }.compactMap { $0["kind"] as? String })
        XCTAssertTrue(deletedKinds.contains("highlight"))
        XCTAssertTrue(deletedKinds.contains("note"))
        XCTAssertEqual(engine.store.record(bookId: "book-1", kind: .highlight, recordId: "h1")?.deleted, true)
        XCTAssertEqual(engine.store.record(bookId: "book-1", kind: .note, recordId: "h1")?.deleted, true)
        XCTAssertTrue(engine.takePendingProjectionRecords(forBookIds: ["book-1"]).isEmpty)
    }
}
