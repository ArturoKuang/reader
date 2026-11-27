import XCTest
import ReaderCore
import ReaderSync

final class DiskFullTests: XCTestCase {
    func testAPIErrorDetectsDiskFull() {
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["code": "disk_full", "message": "free disk is below the floor"]])
        let error = SyncAPIError.parse(status: 507, data: body)
        XCTAssertEqual(error.code, "disk_full")
        XCTAssertEqual(error.status, 507)
        XCTAssertTrue(error.isDiskFull)
        XCTAssertFalse(error.isNetwork)
    }

    func testUpload507EntersStorageFullAndRecordsStillPush() async throws {
        let transport = MockTransport()
        var blobAttempts = 0
        var pushed = false
        transport.handler = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""
            if path.hasSuffix("/v1/health") {
                return jsonResponse(200, ["ok": true, "serverId": "srv_test", "serverVersion": "1.0.0", "protocol": 1, "seq": 0])
            }
            if path.hasSuffix("/v1/pairing/tokens") {
                return jsonResponse(200, [
                    "token": "PAIRTOKEN",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "qr": "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=PAIRTOKEN&server=srv_test",
                ])
            }
            if path.hasSuffix("/v1/pairing/redeem") {
                return jsonResponse(200, ["deviceId": "dev-mac", "credential": "cred-mac", "serverId": "srv_test", "kind": "mac"])
            }
            if path.hasSuffix("/v1/books") && method == "POST" {
                return jsonResponse(200, [
                    "status": "created",
                    "bookId": "sha256:" + "ab" + String(repeating: "0", count: 62),
                    "book": [
                        "bookId": "sha256:" + "ab" + String(repeating: "0", count: 62),
                        "kind": "book",
                        "id": "sha256:" + "ab" + String(repeating: "0", count: 62),
                        "version": 1,
                        "baseVersion": 0,
                        "deleted": false,
                    ],
                ])
            }
            if path.contains("/v1/blobs/") && method == "HEAD" {
                return SyncHTTPResponse(status: 404, headers: ["Upload-Offset": "0"], data: Data())
            }
            if path.contains("/v1/blobs/") && method == "PUT" {
                blobAttempts += 1
                return jsonResponse(507, ["error": ["code": "disk_full", "message": "Mac mini is full"]])
            }
            if path.hasSuffix("/v1/changes") && method == "POST" {
                pushed = true
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let batchId = body?["batchId"] as? String ?? "batch"
                let changes = body?["changes"] as? [[String: Any]] ?? []
                let results: [[String: Any]] = changes.map { change in
                    [
                        "changeId": change["changeId"] as? String ?? "",
                        "status": "applied",
                        "version": 1,
                        "seq": 1,
                    ]
                }
                return jsonResponse(200, ["batchId": batchId, "seq": 1, "results": results])
            }
            if path.hasSuffix("/v1/changes") && method == "GET" {
                return jsonResponse(200, ["changes": [], "cursor": 1, "hasMore": false, "serverId": "srv_test"])
            }
            if path.hasSuffix("/v1/conflicts") {
                return jsonResponse(200, ["conflicts": []])
            }
            if path.hasSuffix("/v1/devices") {
                return jsonResponse(200, ["devices": []])
            }
            return jsonResponse(404, ["error": ["code": "not_found", "message": path]])
        }

        let (engine, _, _) = try makeEngine(transport: transport)
        let data = Data("hello book".utf8)
        let snapshot = BookSyncSnapshot(
            fileURL: URL(fileURLWithPath: "/tmp/VerifyBook.pdf"),
            fileData: data,
            format: "pdf",
            title: "VerifyBook",
            docId: "doc1",
            highlights: [HighlightEntry(id: "h_1", color: 1, page: 1, quote: "hello", noteID: "h_1")],
            notes: [NoteEntry(id: "h_1", page: 1, quote: "hello", body: "a note")],
            words: [],
            isPDF: true,
            page: 1,
            pdfPoint: nil,
            cfi: nil
        )
        try await engine.sync(snapshot: snapshot)
        XCTAssertGreaterThan(blobAttempts, 0)
        XCTAssertTrue(engine.store.storageFull)
        XCTAssertGreaterThan(engine.store.waitingBookCount(), 0)
        XCTAssertTrue(pushed, "highlights and notes must still push after disk_full")
        XCTAssertEqual(engine.status().state, .storageFull)
        XCTAssertEqual(engine.status().label, "Mac mini is full")
        XCTAssertEqual(engine.status().detail, "Books paused. Highlights and notes still sync.")
        XCTAssertEqual(engine.status().bookBadge, "Waiting for space")
    }
}
