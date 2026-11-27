import Foundation

/// Thin rev 3.2 API client. Paths are under `<base>/v1/...` because the base already includes `/v1/reader`.
public final class TailDriveAPI: @unchecked Sendable {
    public let http: SyncHTTPClient

    public init(http: SyncHTTPClient) {
        self.http = http
    }

    public func health() async throws -> HealthResponse {
        let response = try await http.get(path: "/v1/health", authorized: false)
        _ = try http.requireOK(response)
        return try HealthResponse.parse(response.data)
    }

    public func issuePairingToken(kind: String) async throws -> IssuedPairingToken {
        let response = try await http.post(path: "/v1/pairing/tokens", body: ["kind": kind], authorized: http.credential != nil)
        _ = try http.requireOK(response)
        return try IssuedPairingToken.parse(response.data)
    }

    public func redeem(token: String, deviceId: String, name: String, platform: String, appVersion: String?) async throws -> RedeemResponse {
        var body: [String: Any] = [
            "token": token,
            "deviceId": deviceId,
            "name": name,
            "platform": platform,
        ]
        if let appVersion { body["appVersion"] = appVersion }
        let response = try await http.post(path: "/v1/pairing/redeem", body: body, authorized: false)
        _ = try http.requireOK(response)
        return try RedeemResponse.parse(response.data)
    }

    public func devices() async throws -> [PairedDevice] {
        let response = try await http.get(path: "/v1/devices")
        _ = try http.requireOK(response)
        return try PairedDevice.parseList(response.data)
    }

    public func revokeDevice(_ deviceId: String) async throws {
        let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? deviceId
        let response = try await http.delete(path: "/v1/devices/\(encoded)")
        _ = try http.requireOK(response, allowed: [200, 204])
    }

    public func push(batchId: String, changes: [PushChange]) async throws -> PushResponse {
        let body: [String: Any] = [
            "batchId": batchId,
            "changes": changes.map { $0.jsonObject() },
        ]
        let response = try await http.post(path: "/v1/changes", body: body)
        _ = try http.requireOK(response)
        return try PushResponse.parse(response.data)
    }

    public func pull(since: Int, limit: Int = 500) async throws -> PullPage {
        let response = try await http.get(path: "/v1/changes", query: ["since": String(since), "limit": String(min(max(limit, 1), 1000))])
        _ = try http.requireOK(response)
        return try PullPage.parse(response.data)
    }

    public func conflicts(bookId: String? = nil) async throws -> [OpenConflict] {
        var query: [String: String] = [:]
        if let bookId { query["bookId"] = bookId }
        let response = try await http.get(path: "/v1/conflicts", query: query)
        _ = try http.requireOK(response)
        let object = try JSONSupport.object(from: response.data)
        return (object["conflicts"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(OpenConflict.parse) }
    }

    public func resolve(conflictId: String, request: ResolveRequest) async throws -> (version: Int, seq: Int) {
        let encoded = conflictId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conflictId
        let response = try await http.post(path: "/v1/conflicts/\(encoded)/resolve", body: request.jsonObject())
        _ = try http.requireOK(response)
        let object = try JSONSupport.object(from: response.data)
        return (object.int("version") ?? 0, object.int("seq") ?? 0)
    }

    public func registerBook(sha256: String, size: Int, format: String, title: String, filename: String, docId: String?) async throws -> BookRegistration {
        var body: [String: Any] = [
            "sha256": sha256,
            "size": size,
            "format": format,
            "title": title,
            "filename": filename,
        ]
        if let docId, !docId.isEmpty {
            body["docId"] = docId
        }
        let response = try await http.post(path: "/v1/books", body: body)
        _ = try http.requireOK(response)
        return try BookRegistration.parse(response.data)
    }

    public func listBooks() async throws -> [BookListItem] {
        let response = try await http.get(path: "/v1/books")
        _ = try http.requireOK(response)
        return try BookListItem.parseList(response.data)
    }

    /// HEAD: complete blob is 200; missing or partial is 404 with Upload-Offset.
    public func headBlob(sha256: String) async throws -> (complete: Bool, size: Int, offset: Int) {
        let response = try await http.head(path: "/v1/blobs/\(sha256)")
        if response.status == 200 {
            let size = response.header("Content-Length").flatMap(Int.init) ?? 0
            return (true, size, size)
        }
        if response.status == 404 {
            return (false, 0, response.uploadOffset)
        }
        throw SyncAPIError.parse(status: response.status, data: response.data)
    }

    /// Resumable upload. 507 disk_full is returned as an error the engine handles without stopping record sync.
    public func uploadBlob(sha256: String, data: Data, existingOffset: Int = 0) async throws {
        if existingOffset == 0, !data.isEmpty {
            let response = try await http.put(path: "/v1/blobs/\(sha256)", data: data, headers: ["Content-Length": String(data.count)])
            if response.status == 200 || response.status == 201 { return }
            if response.status == 202 { return try await resumeUpload(sha256: sha256, data: data, offset: response.uploadOffset) }
            if response.status == 409 { return try await resumeUpload(sha256: sha256, data: data, offset: response.uploadOffset) }
            throw SyncAPIError.parse(status: response.status, data: response.data)
        }
        try await resumeUpload(sha256: sha256, data: data, offset: existingOffset)
    }

    public func downloadBlob(sha256: String) async throws -> Data {
        var collected = Data()
        var start = 0
        let chunk = 1_048_576
        while true {
            let end = start + chunk - 1
            var requestHeaders = ["Range": "bytes=\(start)-\(end)"]
            let response = try await http.send(method: "GET", path: "/v1/blobs/\(sha256)", extraHeaders: requestHeaders)
            if response.status == 200 {
                return response.data
            }
            if response.status == 206 {
                collected.append(response.data)
                if let range = response.header("Content-Range"), let total = parseTotal(range) {
                    start = collected.count
                    if start >= total { break }
                    continue
                }
                break
            }
            throw SyncAPIError.parse(status: response.status, data: response.data)
        }
        return collected
    }

    private func resumeUpload(sha256: String, data: Data, offset: Int) async throws {
        var cursor = offset
        if cursor > data.count {
            throw SyncAPIError(status: 409, code: "upload_offset_mismatch", message: "server offset is past the local file")
        }
        if cursor == data.count {
            return
        }
        let slice = data.subdata(in: cursor..<data.count)
        let last = data.count - 1
        let headers = [
            "Content-Range": "bytes \(cursor)-\(last)/\(data.count)",
            "Content-Length": String(slice.count),
        ]
        let response = try await http.put(path: "/v1/blobs/\(sha256)", data: slice, headers: headers)
        if response.status == 200 || response.status == 201 { return }
        if response.status == 202 || response.status == 409 {
            if response.uploadOffset == cursor {
                throw SyncAPIError.parse(status: response.status, data: response.data)
            }
            return try await resumeUpload(sha256: sha256, data: data, offset: response.uploadOffset)
        }
        throw SyncAPIError.parse(status: response.status, data: response.data)
    }

    private func parseTotal(_ contentRange: String) -> Int? {
        // bytes 0-1023/5000
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int(contentRange[contentRange.index(after: slash)...])
    }
}
