import Foundation
import ReaderCore
import ReaderSync
import XCTest

// MARK: - Deterministic Seeded PRNG & Configuration

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func nextBool(probabilityTrue: Double = 0.5) -> Bool {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return unit < probabilityTrue
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[nextInt(in: 0...(items.count - 1))]
    }
}

private enum SyncFormalConfig {
    static let defaultSeed: UInt64 = 0x5245_4144_4552_0002
    static let defaultCases: Int = 20

    static var seed: UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["FORMAL_SEED"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return defaultSeed
        }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt64(raw.dropFirst(2), radix: 16) ?? defaultSeed
        }
        return UInt64(raw) ?? defaultSeed
    }

    static var cases: Int {
        guard let raw = ProcessInfo.processInfo.environment["FORMAL_CASES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Int(raw), parsed > 0 else {
            return defaultCases
        }
        // Cap per-schedule count reasonably if huge ReaderCore FORMAL_CASES is passed,
        // while still scaling up cleanly for nightly deep runs.
        return min(parsed, 200)
    }

    static func tag(_ seed: UInt64, caseIndex: Int? = nil) -> String {
        let hex = String(format: "0x%016llx", seed)
        if let caseIndex { return "[FORMAL_SEED=\(hex) case=\(caseIndex)]" }
        return "[FORMAL_SEED=\(hex)]"
    }
}

// MARK: - Canonical JSON Normalization (Key-Order & NSNumber Stable)

private enum CanonicalJSON {
    static func normalize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let d = number.doubleValue
            if d.isFinite && d.rounded() == d && d >= Double(Int.min) && d <= Double(Int.max) {
                return Int(d)
            }
            return d
        }
        if let intVal = value as? Int { return intVal }
        if let doubleVal = value as? Double {
            if doubleVal.isFinite && doubleVal.rounded() == doubleVal && doubleVal >= Double(Int.min) && doubleVal <= Double(Int.max) {
                return Int(doubleVal)
            }
            return doubleVal
        }
        if let stringVal = value as? String { return stringVal }
        if let array = value as? [Any] { return array.map(normalize) }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = normalize(v)
            }
            return out
        }
        return String(describing: value)
    }

    static func stringify(_ value: Any?) -> String {
        let norm = normalize(value)
        if JSONSerialization.isValidJSONObject(norm),
           let data = try? JSONSerialization.data(withJSONObject: norm, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Wrap primitive values in an array for valid JSONSerialization.
        if let data = try? JSONSerialization.data(withJSONObject: [norm], options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(norm)"
    }

    static func stringifyData(_ data: Data?) -> String {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) else {
            return "null"
        }
        return stringify(obj)
    }

    static func sameRecord(
        lhsDeleted: Bool, lhsPayload: [String: Any]?,
        rhsDeleted: Bool, rhsPayload: [String: Any]?
    ) -> Bool {
        lhsDeleted == rhsDeleted && stringify(lhsPayload) == stringify(rhsPayload)
    }
}

// MARK: - In-Process Spec-Compliant Sync Server (SYNC_SPEC rev 3.2)

private struct RecordKey: Hashable {
    var bookId: String
    var kind: RecordKind
    var recordId: String
}

private final class SpecSyncServer: @unchecked Sendable {
    struct StoredDevice {
        var deviceId: String
        var name: String
        var platform: String
        var kind: String // "mac" or "phone"
        var credential: String
        var revoked: Bool = false
    }

    struct BookFile {
        var sha256: String
        var size: Int
        var addedAt: String
    }

    struct StoredBook {
        var bookId: String
        var title: String
        var filename: String
        var format: String
        var docId: String?
        var currentSha256: String
        var files: [BookFile]
        var version: Int
        var seq: Int
    }

    struct VersionSnap {
        var deleted: Bool
        var payload: [String: Any]?
    }

    struct StoredConflictSide {
        var changeId: String
        var deviceId: String
        var version: Int?
        var deleted: Bool
        var payload: [String: Any]?
        var clientTime: String?

        func toJSON() -> [String: Any] {
            var obj: [String: Any] = [
                "changeId": changeId,
                "deviceId": deviceId,
                "deleted": deleted,
            ]
            if let version { obj["version"] = version }
            if let clientTime { obj["clientTime"] = clientTime }
            obj["payload"] = payload ?? NSNull()
            return obj
        }
    }

    struct StoredConflict {
        var conflictId: String
        var bookId: String
        var kind: RecordKind
        var recordId: String
        var baseVersion: Int
        var base: VersionSnap?
        var sides: [StoredConflictSide]
        var openedSeq: Int

        func toJSON() -> [String: Any] {
            var obj: [String: Any] = [
                "conflictId": conflictId,
                "bookId": bookId,
                "kind": kind.rawValue,
                "id": recordId,
                "baseVersion": baseVersion,
                "sides": sides.map { $0.toJSON() },
                "openedSeq": openedSeq,
            ]
            if let base {
                let baseObj: [String: Any] = [
                    "deleted": base.deleted,
                    "payload": base.payload ?? NSNull(),
                ]
                obj["base"] = baseObj
            }
            return obj
        }
    }

    struct StoredRecord {
        var bookId: String
        var kind: RecordKind
        var recordId: String
        var version: Int
        var baseVersion: Int
        var deleted: Bool
        var payload: [String: Any]?
        var deviceId: String
        var changeId: String
        var clientTime: String?
        var seq: Int
        var history: [Int: VersionSnap]
        var conflict: StoredConflict?

        func toEnvelopeJSON() -> [String: Any] {
            var obj: [String: Any] = [
                "bookId": bookId,
                "kind": kind.rawValue,
                "id": recordId,
                "version": version,
                "baseVersion": baseVersion,
                "deleted": deleted,
                "deviceId": deviceId,
                "changeId": changeId,
                "seq": seq,
                "payload": payload ?? NSNull(),
            ]
            if let clientTime { obj["clientTime"] = clientTime }
            if let conflict { obj["conflict"] = conflict.toJSON() }
            return obj
        }
    }

    struct StoredBatch {
        var canonical: String
        var response: [String: Any]
    }

    struct StoredChange {
        var canonical: String
        var result: [String: Any]
    }

    private let lock = NSLock()
    private var _serverId: String
    private var _seq: Int = 0
    private var _diskFull: Bool = false
    private var _pageSize: Int
    private var _tokenCounter: Int = 0
    private var _tokens: [String: (kind: String, boundDeviceId: String?)] = [:]
    private var _devices: [String: StoredDevice] = [:]
    private var _credentials: [String: String] = [:] // credential -> deviceId
    private var _books: [String: StoredBook] = [:]
    private var _blobs: [String: Data] = [:]
    private var _partialBlobs: [String: Data] = [:]
    private var _records: [RecordKey: StoredRecord] = [:]
    private var _batches: [String: StoredBatch] = [:]
    private var _changes: [String: StoredChange] = [:]
    private var _resolvedConflicts: Set<String> = []
    private var _pushCount: Int = 0
    private var _blobPutAttempts: Int = 0

    init(serverId: String = "srv_spec_1", pageSize: Int = 3) {
        self._serverId = serverId
        self._pageSize = pageSize
    }

    var serverId: String {
        lock.lock(); defer { lock.unlock() }
        return _serverId
    }

    var seq: Int {
        lock.lock(); defer { lock.unlock() }
        return _seq
    }

    var diskFull: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _diskFull }
        set { lock.lock(); _diskFull = newValue; lock.unlock() }
    }

    var pushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _pushCount
    }

    var blobPutAttempts: Int {
        lock.lock(); defer { lock.unlock() }
        return _blobPutAttempts
    }

    func record(bookId: String, kind: RecordKind, recordId: String) -> StoredRecord? {
        lock.lock(); defer { lock.unlock() }
        return _records[RecordKey(bookId: bookId, kind: kind, recordId: recordId)]
    }

    func allClientRecords() -> [RecordKey: StoredRecord] {
        lock.lock(); defer { lock.unlock() }
        return _records.filter { $0.key.kind != .book }
    }

    func openConflictCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return _records.values.filter { $0.conflict != nil }.count
    }

    func hasBlob(sha256: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _blobs[sha256] != nil
    }

    func resetServer(newServerId: String) {
        lock.lock(); defer { lock.unlock() }
        _serverId = newServerId
        _seq = 0
        _books.removeAll()
        _blobs.removeAll()
        _partialBlobs.removeAll()
        _records.removeAll()
        _batches.removeAll()
        _changes.removeAll()
        _resolvedConflicts.removeAll()
    }

    func handle(_ request: URLRequest) -> SyncHTTPResponse {
        lock.lock(); defer { lock.unlock() }

        let method = request.httpMethod ?? "GET"
        let fullPath = request.url?.path ?? ""
        let path = stripPrefix(fullPath)
        let query = queryItems(from: request.url)

        if method == "GET" && path == "/v1/health" {
            return json(200, [
                "ok": true,
                "serverId": _serverId,
                "serverVersion": "1.0.0-spec",
                "protocol": 1,
                "seq": _seq,
            ])
        }

        if method == "POST" && path == "/v1/pairing/redeem" {
            return handleRedeem(bodyData: request.httpBody)
        }

        if method == "POST" && path == "/v1/pairing/tokens" {
            let authed = authenticate(request) != nil || request.value(forHTTPHeaderField: "Tailscale-User-Login") != nil
            guard authed else { return apiError(401, "unauthorized", "missing auth") }
            return handleIssueToken(bodyData: request.httpBody)
        }

        guard let device = authenticate(request) else {
            return apiError(401, "unauthorized", "missing or revoked credential")
        }

        if method == "GET" && path == "/v1/devices" {
            let list = _devices.values.map { d -> [String: Any] in
                [
                    "deviceId": d.deviceId,
                    "name": d.name,
                    "platform": d.platform,
                    "kind": d.kind,
                    "revoked": d.revoked,
                ]
            }
            return json(200, ["devices": list])
        }

        if method == "DELETE" && path.hasPrefix("/v1/devices/") {
            let id = String(path.dropFirst("/v1/devices/".count)).removingPercentEncoding ?? ""
            if var dev = _devices[id] {
                dev.revoked = true
                _devices[id] = dev
                _credentials.removeValue(forKey: dev.credential)
            }
            return SyncHTTPResponse(status: 204, headers: [:], data: Data())
        }

        if method == "POST" && (path == "/v1/books" || path == "/v1/books/register") {
            return handleRegisterBook(device: device, bodyData: request.httpBody)
        }

        if method == "GET" && path == "/v1/books" {
            let items = _books.values.map { b -> [String: Any] in
                var obj: [String: Any] = [
                    "bookId": b.bookId,
                    "title": b.title,
                    "filename": b.filename,
                    "format": b.format,
                    "sha256": b.currentSha256,
                    "size": b.files.last?.size ?? 0,
                    "hasBlob": _blobs[b.currentSha256] != nil,
                ]
                if let docId = b.docId { obj["docId"] = docId }
                return obj
            }
            return json(200, ["books": items])
        }

        if path.hasPrefix("/v1/blobs/") {
            let sha = String(path.dropFirst("/v1/blobs/".count))
            if method == "HEAD" { return handleHeadBlob(sha256: sha) }
            if method == "PUT" { return handlePutBlob(sha256: sha, request: request) }
            if method == "GET" { return handleGetBlob(sha256: sha, request: request) }
        }

        if method == "POST" && path == "/v1/changes" {
            return handlePush(device: device, bodyData: request.httpBody)
        }

        if method == "GET" && path == "/v1/changes" {
            return handlePull(query: query)
        }

        if method == "GET" && path == "/v1/conflicts" {
            let bookFilter = query["bookId"]
            let list = _records.values.compactMap(\.conflict)
                .filter { bookFilter == nil || $0.bookId == bookFilter }
                .sorted { $0.openedSeq < $1.openedSeq }
                .map { $0.toJSON() }
            return json(200, ["conflicts": list])
        }

        if method == "POST" && path.hasPrefix("/v1/conflicts/") && path.hasSuffix("/resolve") {
            let start = path.index(path.startIndex, offsetBy: "/v1/conflicts/".count)
            let end = path.index(path.endIndex, offsetBy: -"/resolve".count)
            let conflictId = String(path[start..<end]).removingPercentEncoding ?? String(path[start..<end])
            return handleResolve(device: device, conflictId: conflictId, bodyData: request.httpBody)
        }

        return apiError(404, "not_found", "unknown route \(method) \(path)")
    }

    // MARK: Route Handlers

    private func handleIssueToken(bodyData: Data?) -> SyncHTTPResponse {
        let obj = parseObject(bodyData) ?? [:]
        let kind = (obj["kind"] as? String) ?? "mac"
        _tokenCounter += 1
        let token = "TOK_\(kind.uppercased())_\(_tokenCounter)"
        _tokens[token] = (kind: kind, boundDeviceId: nil)
        let qr = "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=\(token)&server=\(_serverId)"
        return json(200, [
            "token": token,
            "expiresAt": "2099-01-01T00:00:00Z",
            "qr": qr,
        ])
    }

    private func handleRedeem(bodyData: Data?) -> SyncHTTPResponse {
        guard let obj = parseObject(bodyData),
              let token = obj["token"] as? String,
              let deviceId = obj["deviceId"] as? String,
              let name = obj["name"] as? String,
              let platform = obj["platform"] as? String else {
            return apiError(400, "bad_request", "missing redeem fields")
        }
        guard var issued = _tokens[token] else {
            return apiError(403, "forbidden", "unknown pairing token")
        }
        if let bound = issued.boundDeviceId, bound != deviceId {
            return apiError(403, "forbidden", "token bound to another device")
        }
        issued.boundDeviceId = deviceId
        _tokens[token] = issued

        if let existing = _devices[deviceId] {
            _credentials.removeValue(forKey: existing.credential)
        }
        let cred = "cred_\(deviceId)_\(_tokenCounter)_\(_credentials.count + 1)"
        let dev = StoredDevice(deviceId: deviceId, name: name, platform: platform, kind: issued.kind, credential: cred, revoked: false)
        _devices[deviceId] = dev
        _credentials[cred] = deviceId
        return json(200, [
            "deviceId": deviceId,
            "credential": cred,
            "serverId": _serverId,
            "kind": issued.kind,
        ])
    }

    private func handleRegisterBook(device: StoredDevice, bodyData: Data?) -> SyncHTTPResponse {
        guard let obj = parseObject(bodyData),
              let sha256 = obj["sha256"] as? String,
              let size = asInt(obj["size"]),
              let format = obj["format"] as? String,
              let title = obj["title"] as? String,
              let filename = obj["filename"] as? String else {
            return apiError(400, "bad_request", "invalid book register payload")
        }
        let docId = (obj["docId"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // Rule 1: sha256 already known in any book's files list -> existing (no seq bump).
        if let existing = _books.values.first(where: { $0.files.contains(where: { $0.sha256 == sha256 }) }) {
            let env = _records[RecordKey(bookId: existing.bookId, kind: .book, recordId: existing.bookId)]?.toEnvelopeJSON()
            var resp: [String: Any] = ["status": "existing", "bookId": existing.bookId]
            if let env { resp["book"] = env }
            return json(200, resp)
        }

        // Rule 2: non-empty docId matches an existing book -> attach new file, bump version & seq.
        if let docId, var existing = _books.values.first(where: { $0.docId == docId }) {
            existing.files.append(BookFile(sha256: sha256, size: size, addedAt: "2026-11-28T00:00:00Z"))
            existing.currentSha256 = sha256
            existing.title = title
            existing.filename = filename
            existing.format = format
            let env = writeBookRecord(device: device, book: &existing)
            _books[existing.bookId] = existing
            return json(200, ["status": "attached", "bookId": existing.bookId, "book": env])
        }

        // Rule 3: create new book with bookId = sha256:<sha256>.
        let bookId = "sha256:\(sha256)"
        var created = StoredBook(
            bookId: bookId,
            title: title,
            filename: filename,
            format: format,
            docId: docId,
            currentSha256: sha256,
            files: [BookFile(sha256: sha256, size: size, addedAt: "2026-11-28T00:00:00Z")],
            version: 0,
            seq: 0
        )
        let env = writeBookRecord(device: device, book: &created)
        _books[bookId] = created
        return json(200, ["status": "created", "bookId": bookId, "book": env])
    }

    private func writeBookRecord(device: StoredDevice, book: inout StoredBook) -> [String: Any] {
        _seq += 1
        let prevVersion = book.version
        book.version += 1
        book.seq = _seq
        var payload: [String: Any] = [
            "title": book.title,
            "filename": book.filename,
            "format": book.format,
            "currentSha256": book.currentSha256,
            "files": book.files.map { ["sha256": $0.sha256, "size": $0.size, "addedAt": $0.addedAt] },
            "extras": [:] as [String: Any],
        ]
        if let docId = book.docId { payload["docId"] = docId }
        let key = RecordKey(bookId: book.bookId, kind: .book, recordId: book.bookId)
        var history = _records[key]?.history ?? [:]
        history[book.version] = VersionSnap(deleted: false, payload: payload)
        let rec = StoredRecord(
            bookId: book.bookId,
            kind: .book,
            recordId: book.bookId,
            version: book.version,
            baseVersion: prevVersion,
            deleted: false,
            payload: payload,
            deviceId: device.deviceId,
            changeId: "book_\(book.bookId)_\(book.version)",
            clientTime: "2026-11-28T00:00:00Z",
            seq: _seq,
            history: history,
            conflict: nil
        )
        _records[key] = rec
        return rec.toEnvelopeJSON()
    }

    private func handleHeadBlob(sha256: String) -> SyncHTTPResponse {
        if let complete = _blobs[sha256] {
            return SyncHTTPResponse(status: 200, headers: ["Content-Length": String(complete.count)], data: Data())
        }
        let offset = _partialBlobs[sha256]?.count ?? 0
        return SyncHTTPResponse(status: 404, headers: ["Upload-Offset": String(offset)], data: Data())
    }

    private func handlePutBlob(sha256: String, request: URLRequest) -> SyncHTTPResponse {
        _blobPutAttempts += 1
        if _diskFull {
            return apiError(507, "disk_full", "free disk is below the floor")
        }
        let chunk = request.httpBody ?? Data()
        if let range = request.value(forHTTPHeaderField: "Content-Range") {
            // Format: bytes start-end/total
            let parts = range.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
            guard parts.count == 2, let total = Int(parts[1]) else {
                return apiError(400, "bad_request", "invalid Content-Range")
            }
            let bounds = parts[0].split(separator: "-")
            guard bounds.count == 2, let start = Int(bounds[0]) else {
                return apiError(400, "bad_request", "invalid Content-Range bounds")
            }
            var buffer = _partialBlobs[sha256] ?? Data()
            if start != buffer.count {
                return SyncHTTPResponse(status: 409, headers: ["Upload-Offset": String(buffer.count)], data: Data())
            }
            buffer.append(chunk)
            if buffer.count < total {
                _partialBlobs[sha256] = buffer
                return SyncHTTPResponse(status: 202, headers: ["Upload-Offset": String(buffer.count)], data: Data())
            }
            guard SHA256.hex(buffer) == sha256 else {
                _partialBlobs.removeValue(forKey: sha256)
                return apiError(400, "hash_mismatch", "uploaded blob sha256 mismatch")
            }
            _partialBlobs.removeValue(forKey: sha256)
            _blobs[sha256] = buffer
            return json(201, ["ok": true, "sha256": sha256])
        } else {
            guard SHA256.hex(chunk) == sha256 else {
                return apiError(400, "hash_mismatch", "uploaded blob sha256 mismatch")
            }
            _partialBlobs.removeValue(forKey: sha256)
            _blobs[sha256] = chunk
            return json(201, ["ok": true, "sha256": sha256])
        }
    }

    private func handleGetBlob(sha256: String, request: URLRequest) -> SyncHTTPResponse {
        guard let data = _blobs[sha256] else {
            return apiError(404, "not_found", "blob not found")
        }
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-")
            if let start = bounds.first.flatMap({ Int($0) }) {
                let requestedEnd = bounds.count > 1 ? (Int(bounds[1]) ?? (data.count - 1)) : (data.count - 1)
                if start >= data.count || start > requestedEnd {
                    return apiError(416, "range_not_satisfiable", "range outside blob")
                }
                let end = min(requestedEnd, data.count - 1)
                let slice = data.subdata(in: start..<(end + 1))
                return SyncHTTPResponse(
                    status: 206,
                    headers: ["Content-Range": "bytes \(start)-\(end)/\(data.count)"],
                    data: slice
                )
            }
        }
        return SyncHTTPResponse(status: 200, headers: ["Content-Length": String(data.count)], data: data)
    }

    private func handlePush(device: StoredDevice, bodyData: Data?) -> SyncHTTPResponse {
        _pushCount += 1
        guard let obj = parseObject(bodyData),
              let batchId = obj["batchId"] as? String, !batchId.isEmpty,
              let rawChanges = obj["changes"] as? [[String: Any]] else {
            return apiError(400, "bad_request", "batchId and changes are required")
        }
        if rawChanges.count > 500 {
            return apiError(413, "too_large", "max 500 changes per batch")
        }
        var seenKeys: Set<RecordKey> = []
        for change in rawChanges {
            guard let bookId = change["bookId"] as? String,
                  let kindStr = change["kind"] as? String,
                  let kind = RecordKind(rawValue: kindStr),
                  let recordId = change["id"] as? String else {
                return apiError(400, "bad_request", "invalid change item")
            }
            if kind == .book {
                return apiError(400, "use_register", "register books via POST /v1/books")
            }
            let key = RecordKey(bookId: bookId, kind: kind, recordId: recordId)
            if !seenKeys.insert(key).inserted {
                return apiError(400, "bad_request", "duplicate record key in batch")
            }
        }

        let canonicalBatch = CanonicalJSON.stringify(obj)
        if let existing = _batches[batchId] {
            if existing.canonical == canonicalBatch {
                return json(200, existing.response)
            }
            return apiError(422, "change_id_reused", "batchId reused with different body")
        }

        var results: [[String: Any]] = []
        for change in rawChanges {
            guard let changeId = change["changeId"] as? String else {
                return apiError(400, "bad_request", "missing changeId")
            }
            let canonicalChange = CanonicalJSON.stringify(change)
            if let prior = _changes[changeId] {
                if prior.canonical == canonicalChange {
                    results.append(prior.result)
                    continue
                }
                let rej = rejected(changeId: changeId, code: "change_id_reused", message: "changeId reused with different body")
                results.append(rej)
                continue
            }
            let result = applyChange(device: device, change: change)
            _changes[changeId] = StoredChange(canonical: canonicalChange, result: result)
            results.append(result)
        }

        let response: [String: Any] = [
            "batchId": batchId,
            "seq": _seq,
            "results": results,
        ]
        _batches[batchId] = StoredBatch(canonical: canonicalBatch, response: response)
        return json(200, response)
    }

    private func applyChange(device: StoredDevice, change: [String: Any]) -> [String: Any] {
        guard let changeId = change["changeId"] as? String,
              let bookId = change["bookId"] as? String,
              let kindStr = change["kind"] as? String,
              let kind = RecordKind(rawValue: kindStr),
              let recordId = change["id"] as? String,
              let baseVersion = asInt(change["baseVersion"]), baseVersion >= 0,
              let deleted = asBool(change["deleted"]) else {
            return rejected(changeId: (change["changeId"] as? String) ?? "", code: "bad_request", message: "malformed change")
        }
        let clientTime = change["clientTime"] as? String
        let payload: [String: Any]? = (change["payload"] is NSNull) ? nil : (change["payload"] as? [String: Any])

        if kind == .book {
            return rejected(changeId: changeId, code: "use_register", message: "book records use register")
        }
        guard _books[bookId] != nil else {
            return rejected(changeId: changeId, code: "unknown_book", message: "book not registered")
        }

        let key = RecordKey(bookId: bookId, kind: kind, recordId: recordId)

        // Position records: owner-only, never deleted, always fast-forward (no conflict).
        if kind == .position {
            if deleted {
                return rejected(changeId: changeId, code: "bad_request", message: "positions cannot be deleted")
            }
            let expectedId = "p_\(bookId)_\(device.deviceId)"
            let payloadDevice = payload?["deviceId"] as? String
            if recordId != expectedId || payloadDevice != device.deviceId {
                return rejected(changeId: changeId, code: "not_owner", message: "only owning device may write position")
            }
            if let head = _records[key],
               CanonicalJSON.sameRecord(lhsDeleted: false, lhsPayload: payload, rhsDeleted: head.deleted, rhsPayload: head.payload) {
                return ["changeId": changeId, "status": "noop", "version": head.version, "seq": head.seq]
            }
            let nextVersion = (_records[key]?.version ?? 0) + 1
            return writeRecord(device: device, key: key, changeId: changeId, baseVersion: baseVersion, deleted: false, payload: payload, clientTime: clientTime, version: nextVersion)
        }

        // Standard §6 merge/conflict rules.
        guard var head = _records[key] else {
            if baseVersion != 0 {
                return rejected(changeId: changeId, code: "bad_base", message: "create requires baseVersion 0")
            }
            return writeRecord(device: device, key: key, changeId: changeId, baseVersion: 0, deleted: deleted, payload: payload, clientTime: clientTime, version: 1)
        }

        if baseVersion > head.version {
            return rejected(changeId: changeId, code: "bad_base", message: "baseVersion ahead of server head")
        }

        if CanonicalJSON.sameRecord(lhsDeleted: deleted, lhsPayload: payload, rhsDeleted: head.deleted, rhsPayload: head.payload) {
            return ["changeId": changeId, "status": "noop", "version": head.version, "seq": head.seq]
        }

        if baseVersion == head.version {
            return writeRecord(device: device, key: key, changeId: changeId, baseVersion: baseVersion, deleted: deleted, payload: payload, clientTime: clientTime, version: head.version + 1)
        }

        // baseVersion < head.version -> check duplicate side, else open/append conflict.
        if let existingConflict = head.conflict,
           existingConflict.sides.contains(where: { CanonicalJSON.sameRecord(lhsDeleted: deleted, lhsPayload: payload, rhsDeleted: $0.deleted, rhsPayload: $0.payload) }) {
            return ["changeId": changeId, "status": "noop", "version": head.version, "seq": head.seq]
        }

        _seq += 1
        let incomingSide = StoredConflictSide(
            changeId: changeId,
            deviceId: device.deviceId,
            version: nil,
            deleted: deleted,
            payload: payload,
            clientTime: clientTime
        )
        if var open = head.conflict {
            open.sides.append(incomingSide)
            head.conflict = open
        } else {
            let headSide = StoredConflictSide(
                changeId: head.changeId,
                deviceId: head.deviceId,
                version: head.version,
                deleted: head.deleted,
                payload: head.payload,
                clientTime: head.clientTime
            )
            head.conflict = StoredConflict(
                conflictId: "cf_\(_seq)",
                bookId: head.bookId,
                kind: head.kind,
                recordId: head.recordId,
                baseVersion: baseVersion,
                base: head.history[baseVersion],
                sides: [headSide, incomingSide],
                openedSeq: _seq
            )
        }
        head.seq = _seq
        _records[key] = head
        return [
            "changeId": changeId,
            "status": "conflict",
            "version": head.version,
            "seq": _seq,
            "conflictId": head.conflict!.conflictId,
        ]
    }

    private func writeRecord(
        device: StoredDevice,
        key: RecordKey,
        changeId: String,
        baseVersion: Int,
        deleted: Bool,
        payload: [String: Any]?,
        clientTime: String?,
        version: Int
    ) -> [String: Any] {
        _seq += 1
        var history = _records[key]?.history ?? [:]
        history[version] = VersionSnap(deleted: deleted, payload: payload)
        let rec = StoredRecord(
            bookId: key.bookId,
            kind: key.kind,
            recordId: key.recordId,
            version: version,
            baseVersion: baseVersion,
            deleted: deleted,
            payload: payload,
            deviceId: device.deviceId,
            changeId: changeId,
            clientTime: clientTime,
            seq: _seq,
            history: history,
            conflict: nil
        )
        _records[key] = rec
        return [
            "changeId": changeId,
            "status": "applied",
            "version": version,
            "seq": _seq,
        ]
    }

    private func handlePull(query: [String: String]) -> SyncHTTPResponse {
        let since = Int(query["since"] ?? "0") ?? 0
        let reqLimit = Int(query["limit"] ?? "500") ?? 500
        let limit = min(max(reqLimit, 1), _pageSize)

        let matching = _records.values
            .filter { $0.seq > since }
            .sorted { $0.seq < $1.seq }
        let page = Array(matching.prefix(limit))
        let hasMore = matching.count > page.count
        let cursor = hasMore ? (page.last?.seq ?? since) : max(since, _seq)
        return json(200, [
            "changes": page.map { $0.toEnvelopeJSON() },
            "cursor": cursor,
            "hasMore": hasMore,
            "serverId": _serverId,
        ])
    }

    private func handleResolve(device: StoredDevice, conflictId: String, bodyData: Data?) -> SyncHTTPResponse {
        guard device.kind == "mac" else {
            return apiError(403, "forbidden", "only Mac devices may resolve conflicts")
        }
        if _resolvedConflicts.contains(conflictId) {
            return apiError(409, "already_resolved", "conflict already resolved")
        }
        guard let obj = parseObject(bodyData),
              let changeId = obj["changeId"] as? String,
              let baseVersion = asInt(obj["baseVersion"]),
              let deleted = asBool(obj["deleted"]) else {
            return apiError(400, "bad_request", "invalid resolve request")
        }
        let payload: [String: Any]? = (obj["payload"] is NSNull) ? nil : (obj["payload"] as? [String: Any])

        guard let entry = _records.first(where: { $0.value.conflict?.conflictId == conflictId }) else {
            return apiError(404, "not_found", "unknown conflict")
        }
        let key = entry.key
        let head = entry.value
        guard baseVersion == head.version else {
            return apiError(409, "stale_base", "resolve baseVersion \(baseVersion) != head version \(head.version)")
        }

        _resolvedConflicts.insert(conflictId)
        _seq += 1
        let nextVersion = head.version + 1
        var history = head.history
        history[nextVersion] = VersionSnap(deleted: deleted, payload: payload)
        let updated = StoredRecord(
            bookId: head.bookId,
            kind: head.kind,
            recordId: head.recordId,
            version: nextVersion,
            baseVersion: baseVersion,
            deleted: deleted,
            payload: payload,
            deviceId: device.deviceId,
            changeId: changeId,
            clientTime: "2026-11-28T00:00:00Z",
            seq: _seq,
            history: history,
            conflict: nil
        )
        _records[key] = updated
        return json(200, [
            "version": nextVersion,
            "seq": _seq,
        ])
    }

    // MARK: Helpers

    private func authenticate(_ request: URLRequest) -> StoredDevice? {
        guard let auth = request.value(forHTTPHeaderField: "Authorization"),
              auth.hasPrefix("Bearer ") else { return nil }
        let token = String(auth.dropFirst("Bearer ".count))
        guard let deviceId = _credentials[token],
              let device = _devices[deviceId], !device.revoked else { return nil }
        return device
    }

    private func stripPrefix(_ path: String) -> String {
        let prefix = "/v1/reader"
        if path == prefix { return "/" }
        if path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count)) }
        return path
    }

    private func queryItems(from url: URL?) -> [String: String] {
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    private func parseObject(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func asInt(_ any: Any?) -> Int? {
        if let v = any as? Int { return v }
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        return nil
    }

    private func asBool(_ any: Any?) -> Bool? {
        if let v = any as? Bool { return v }
        if let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }

    private func rejected(changeId: String, code: String, message: String) -> [String: Any] {
        ["changeId": changeId, "status": "rejected", "error": ["code": code, "message": message]]
    }

    private func json(_ status: Int, _ obj: [String: Any]) -> SyncHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return SyncHTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: data)
    }

    private func apiError(_ status: Int, _ code: String, _ message: String) -> SyncHTTPResponse {
        json(status, ["error": ["code": code, "message": message]])
    }
}

// MARK: - Per-Device Fault-Injecting Transport

private final class FaultInjectingTransport: SyncTransporting, @unchecked Sendable {
    let server: SpecSyncServer
    private let lock = NSLock()
    var offline = false
    var dropNextPushResponse = false
    var transient503Count = 0
    var rotateServerIdOnNextPullTo: String?
    var maxPullCallsInWindow: Int?
    var pullCalls = 0
    var onBeforePull: (() -> Void)?

    init(server: SpecSyncServer) {
        self.server = server
    }

    func perform(_ request: URLRequest) async throws -> SyncHTTPResponse {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let isPull = method == "GET" && path.hasSuffix("/v1/changes")
        let isPush = method == "POST" && path.hasSuffix("/v1/changes")

        var shouldThrowOffline = false
        var shouldReturn503 = false
        var shouldDropAfter = false
        var rotateTo: String?
        var pullHook: (() -> Void)?
        var exceededPullLimit = false
        var pullLimitValue = 0

        lock.withLock {
            if offline {
                shouldThrowOffline = true
            } else if transient503Count > 0 {
                transient503Count -= 1
                shouldReturn503 = true
            } else {
                if isPush && dropNextPushResponse {
                    dropNextPushResponse = false
                    shouldDropAfter = true
                }
                if isPull {
                    pullCalls += 1
                    if let maxPulls = maxPullCallsInWindow, pullCalls > maxPulls {
                        exceededPullLimit = true
                        pullLimitValue = maxPulls
                    }
                    if let nextServerId = rotateServerIdOnNextPullTo {
                        rotateTo = nextServerId
                        rotateServerIdOnNextPullTo = nil
                    }
                    if let hook = onBeforePull {
                        pullHook = hook
                        onBeforePull = nil
                    }
                }
            }
        }

        if shouldThrowOffline {
            throw SyncAPIError.network("simulated offline")
        }
        if exceededPullLimit {
            throw SyncAPIError(status: 0, code: "infinite_pull_loop", message: "pullAll exceeded safety limit of \(pullLimitValue) pulls")
        }
        if shouldReturn503 {
            return jsonResponse(503, ["error": ["code": "server_busy", "message": "simulated 503"]])
        }
        if let hook = pullHook {
            hook()
        }
        if let rotateTo {
            server.resetServer(newServerId: rotateTo)
        }

        let response = server.handle(request)
        if shouldDropAfter {
            throw SyncAPIError.network("simulated dropped response after server commit")
        }
        return response
    }
}

private final class RecordingVaultWriter: SyncVaultWriting {
    var receivedBatches: [[RecordEnvelope]] = []

    func applyAcceptedRecords(_ records: [RecordEnvelope], vaultRoot: URL?) throws {
        receivedBatches.append(records)
    }

    var allEnvelopes: [RecordEnvelope] {
        receivedBatches.flatMap { $0 }
    }
}

// MARK: - Two-Device Test Harness

private struct PairedDeviceNode {
    let name: String
    let engine: SyncEngine
    let transport: FaultInjectingTransport
    let credentials: InMemoryCredentialStore
    let directory: URL
    let vaultWriter: RecordingVaultWriter
    var lastObservedServerId: String?
    var lastObservedCursor: Int = 0

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeTwoDeviceCluster(pageSize: Int = 3) async throws -> (server: SpecSyncServer, mac: PairedDeviceNode, phone: PairedDeviceNode) {
    let server = SpecSyncServer(serverId: "srv_1", pageSize: pageSize)

    func makeNode(name: String, login: String?) throws -> PairedDeviceNode {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-formal-sync-\(name)-\(UUID().uuidString)", isDirectory: true)
        let creds = InMemoryCredentialStore()
        let transport = FaultInjectingTransport(server: server)
        let config = SyncClientConfiguration(
            baseURL: SyncClientConfiguration.loopbackTestURL,
            loopbackLogin: login,
            deviceName: name,
            appVersion: "formal-test"
        )
        let engine = try SyncEngine(directory: dir, configuration: config, credentials: creds, transport: transport)
        let writer = RecordingVaultWriter()
        engine.vaultWriter = writer
        return PairedDeviceNode(name: name, engine: engine, transport: transport, credentials: creds, directory: dir, vaultWriter: writer)
    }

    var mac = try makeNode(name: "Mac", login: "arturo@local")
    var phone = try makeNode(name: "Phone", login: nil)

    // Pair Mac as kind="mac"
    _ = try await mac.engine.ensureMacPaired()
    mac.lastObservedServerId = mac.engine.store.serverId
    mac.lastObservedCursor = mac.engine.store.cursor

    // Pair Phone via Mac-issued phone QR (kind="phone")
    let qrToken = try await mac.engine.issuePhoneQR()
    let parsedQR = try PairingQR.parse(qrToken.qr)
    let redeemed = try await phone.engine.api.redeem(
        token: parsedQR.token,
        deviceId: phone.engine.macDeviceId,
        name: "Phone",
        platform: "ios",
        appVersion: "formal-test"
    )
    try phone.credentials.save(account: SyncKeychainAccount.credential, secret: redeemed.credential)
    try phone.credentials.save(account: SyncKeychainAccount.deviceId, secret: redeemed.deviceId)
    try phone.credentials.save(account: SyncKeychainAccount.serverId, secret: redeemed.serverId)
    phone.engine.http.credential = redeemed.credential
    phone.engine.store.serverId = redeemed.serverId
    phone.lastObservedServerId = redeemed.serverId
    phone.lastObservedCursor = 0

    return (server, mac, phone)
}

private func enqueueDirectEdit(
    on engine: SyncEngine,
    bookId: String,
    kind: RecordKind,
    recordId: String,
    payload: [String: Any],
    deleted: Bool = false,
    overrideBaseVersion: Int? = nil
) throws {
    let current = engine.store.record(bookId: bookId, kind: kind, recordId: recordId)
    let base = overrideBaseVersion ?? current?.serverVersion ?? 0
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let item = OutboxItem(
        changeId: newChangeId(),
        batchId: newBatchId(),
        bookId: bookId,
        kind: kind,
        recordId: recordId,
        baseVersion: base,
        deleted: deleted,
        payloadJSON: data,
        clientTime: "2026-11-28T00:00:00Z"
    )
    engine.store.mergeOutbox(for: (bookId, kind, recordId), into: item)
    engine.store.upsertRecord(LocalRecordState(
        bookId: bookId,
        kind: kind,
        recordId: recordId,
        serverVersion: base,
        dirty: true,
        deleted: deleted,
        payloadJSON: data
    ))
}

private func checkClientInvariants(
    node: inout PairedDeviceNode,
    context: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    // Invariant 1: Outbox has at most 1 item per (bookId, kind, recordId).
    let outbox = node.engine.store.outbox()
    var seen: Set<RecordKey> = []
    for item in outbox {
        let key = RecordKey(bookId: item.bookId, kind: item.kind, recordId: item.recordId)
        XCTAssertTrue(
            seen.insert(key).inserted,
            "\(context) [\(node.name)] duplicate outbox entry for \(key)",
            file: file, line: line
        )
    }

    // Invariant 2: Cursor is monotonic while serverId is unchanged.
    let currentServerId = node.engine.store.serverId
    let currentCursor = node.engine.store.cursor
    if let prevServer = node.lastObservedServerId, prevServer == currentServerId {
        XCTAssertGreaterThanOrEqual(
            currentCursor, node.lastObservedCursor,
            "\(context) [\(node.name)] cursor regressed from \(node.lastObservedCursor) to \(currentCursor) under unchanged serverId=\(prevServer)",
            file: file, line: line
        )
    }
    node.lastObservedServerId = currentServerId
    node.lastObservedCursor = currentCursor
}

// MARK: - Formal Sync Harness Tests

final class FormalSyncHarnessTests: XCTestCase {

    // MARK: 1. Spec Server & Protocol Conformance Self-Check

    func testSpecServerEnforcesRev32BookRegisterIdempotencyAndConflictRules() async throws {
        let (server, mac, phone) = try await makeTwoDeviceCluster()
        defer { mac.cleanup(); phone.cleanup() }

        let bytesA = Data("book-edition-1".utf8)
        let bytesB = Data("book-edition-2".utf8)
        let shaA = SHA256.hex(bytesA)
        let shaB = SHA256.hex(bytesB)

        // Book register Rule 3 (create) -> Rule 1 (existing) -> Rule 2 (attach via docId).
        let reg1 = try await mac.engine.api.registerBook(sha256: shaA, size: bytesA.count, format: "pdf", title: "Origin", filename: "origin.pdf", docId: "doc_origin")
        XCTAssertEqual(reg1.status, "created")
        XCTAssertEqual(reg1.bookId, "sha256:\(shaA)")
        let seqAfterCreate = server.seq

        let reg2 = try await mac.engine.api.registerBook(sha256: shaA, size: bytesA.count, format: "pdf", title: "Origin", filename: "origin.pdf", docId: "doc_origin")
        XCTAssertEqual(reg2.status, "existing")
        XCTAssertEqual(reg2.bookId, reg1.bookId)
        XCTAssertEqual(server.seq, seqAfterCreate, "existing register must not bump seq")

        let reg3 = try await mac.engine.api.registerBook(sha256: shaB, size: bytesB.count, format: "pdf", title: "Origin 2nd", filename: "origin2.pdf", docId: "doc_origin")
        XCTAssertEqual(reg3.status, "attached")
        XCTAssertEqual(reg3.bookId, reg1.bookId)
        XCTAssertGreaterThan(server.seq, seqAfterCreate)

        // Batch idempotency: same batchId + same body replays; different body returns 422 change_id_reused.
        let notePayload: [String: Any] = ["quote": "q", "prefix": "", "suffix": "", "ai": false, "scope": "passage", "body": "v1", "extras": [:]]
        let change = PushChange(changeId: "c_idem_1", bookId: reg1.bookId, kind: .note, recordId: "n_1", baseVersion: 0, deleted: false, clientTime: "2026-11-28T00:00:00Z", payload: notePayload)
        let push1 = try await mac.engine.api.push(batchId: "b_idem_1", changes: [change])
        let push2 = try await mac.engine.api.push(batchId: "b_idem_1", changes: [change])
        XCTAssertEqual(push1, push2)

        var mutated = change
        mutated.payload = ["quote": "q", "prefix": "", "suffix": "", "ai": false, "scope": "passage", "body": "DIFFERENT", "extras": [:]]
        do {
            _ = try await mac.engine.api.push(batchId: "b_idem_1", changes: [mutated])
            XCTFail("expected 422 change_id_reused on mismatched batchId replay")
        } catch let err as SyncAPIError {
            XCTAssertEqual(err.status, 422)
            XCTAssertEqual(err.code, "change_id_reused")
        }

        // Open conflict and verify: Phone gets 403 on resolve, Mac gets 409 stale_base on wrong baseVersion.
        let macEdit = PushChange(changeId: "c_m2", bookId: reg1.bookId, kind: .note, recordId: "n_1", baseVersion: 1, deleted: false, clientTime: "2026-11-28T00:00:01Z", payload: ["quote": "q", "prefix": "", "suffix": "", "ai": false, "scope": "passage", "body": "mac-v2", "extras": [:]])
        _ = try await mac.engine.api.push(batchId: "b_m2", changes: [macEdit])
        let phoneEdit = PushChange(changeId: "c_p2", bookId: reg1.bookId, kind: .note, recordId: "n_1", baseVersion: 1, deleted: false, clientTime: "2026-11-28T00:00:02Z", payload: ["quote": "q", "prefix": "", "suffix": "", "ai": false, "scope": "passage", "body": "phone-v2", "extras": [:]])
        let conflictResp = try await phone.engine.api.push(batchId: "b_p2", changes: [phoneEdit])
        XCTAssertEqual(conflictResp.results.first?.status, "conflict")
        let conflictId = try XCTUnwrap(conflictResp.results.first?.conflictId)

        let openConflicts = try await mac.engine.api.conflicts()
        let openConflict = try XCTUnwrap(openConflicts.first(where: { $0.conflictId == conflictId }))
        let validPrepared = try ConflictResolution.prepare(conflict: openConflict, choice: .keepSide(0), macDeviceIds: [mac.engine.macDeviceId])

        do {
            _ = try await phone.engine.api.resolve(conflictId: conflictId, request: validPrepared.request)
            XCTFail("phone must be forbidden from resolving conflicts")
        } catch let err as SyncAPIError {
            XCTAssertEqual(err.status, 403)
            XCTAssertEqual(err.code, "forbidden")
        }

        var staleRequest = validPrepared.request
        staleRequest.baseVersion = 1
        do {
            _ = try await mac.engine.api.resolve(conflictId: conflictId, request: staleRequest)
            XCTFail("resolve with baseVersion != head.version must fail with 409 stale_base")
        } catch let err as SyncAPIError {
            XCTAssertEqual(err.status, 409)
            XCTAssertEqual(err.code, "stale_base")
        }
    }

    // MARK: 2. Outbox Single-Entry-Per-Key Invariant

    func testOutboxHasAtMostOneItemPerRecordAcrossRandomizedOfflineEdits() async throws {
        let seed = SyncFormalConfig.seed ^ 0x10
        var rng = SplitMix64(seed: seed)
        var (server, mac, phone) = try await makeTwoDeviceCluster()
        defer { mac.cleanup(); phone.cleanup() }

        let bookData = Data("outbox-test-book".utf8)
        let reg = try await mac.engine.api.registerBook(sha256: SHA256.hex(bookData), size: bookData.count, format: "pdf", title: "Book", filename: "b.pdf", docId: "doc1")
        let bookId = reg.bookId
        mac.engine.store.rememberBook(sha256: SHA256.hex(bookData), bookId: bookId, format: "pdf", title: "Book", filename: "b.pdf", docId: "doc1", size: bookData.count, waitingForSpace: false)

        mac.transport.offline = true
        let recordIds = ["n_0", "n_1", "n_2", "n_3"]
        var latestExpected: [String: (body: String, deleted: Bool)] = [:]

        let edits = max(SyncFormalConfig.cases * 2, 40)
        for step in 0..<edits {
            let rid = rng.pick(recordIds)
            let deleted = rng.nextBool(probabilityTrue: 0.2)
            let body = "edit_\(step)_\(rng.nextInt(in: 0...999))"
            let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: 1, quote: "q", body: body), highlightId: nil)
            try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload, deleted: deleted)
            latestExpected[rid] = (body, deleted)
            checkClientInvariants(node: &mac, context: "\(SyncFormalConfig.tag(seed)) step=\(step)")
            XCTAssertLessThanOrEqual(mac.engine.store.outbox().count, recordIds.count)
        }

        // Go online and sync -> every latest edit must reach the server and outbox must drain.
        mac.transport.offline = false
        try await mac.engine.sync()
        checkClientInvariants(node: &mac, context: "\(SyncFormalConfig.tag(seed)) after-sync")
        XCTAssertTrue(mac.engine.store.outbox().isEmpty)

        for (rid, exp) in latestExpected {
            let head = try XCTUnwrap(server.record(bookId: bookId, kind: .note, recordId: rid))
            XCTAssertEqual(head.deleted, exp.deleted)
            XCTAssertEqual(head.payload?["body"] as? String, exp.body)
        }
    }

    // MARK: 3. Pull Never Overwrites Locally Dirty Record Invariant

    func testPullNeverOverwritesLocallyDirtyRecord() async throws {
        let seed = SyncFormalConfig.seed ^ 0x11
        var rng = SplitMix64(seed: seed)
        var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
        defer { mac.cleanup(); phone.cleanup() }

        let bookData = Data("dirty-protect-book".utf8)
        let reg = try await mac.engine.api.registerBook(sha256: SHA256.hex(bookData), size: bookData.count, format: "pdf", title: "DirtyBook", filename: "d.pdf", docId: "doc_dirty")
        let bookId = reg.bookId

        // Seed 4 notes from Phone and pull onto Mac so both start clean at v1.
        for i in 0..<4 {
            let payload = RecordAdapter.notePayload(NoteEntry(id: "n_\(i)", page: i + 1, quote: "q\(i)", body: "base_\(i)"), highlightId: nil)
            try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: "n_\(i)", payload: payload)
        }
        try await phone.engine.sync()
        try await mac.engine.sync()

        for round in 0..<min(SyncFormalConfig.cases, 25) {
            let dirtyId = "n_\(rng.nextInt(in: 0...3))"
            let cleanId = "n_\((Int(dirtyId.dropFirst(2))! + 1) % 4)"
            let remoteBodyDirty = "phone_remote_\(round)"
            let remoteBodyClean = "phone_clean_\(round)"
            let localDirtyBody = "mac_unpushed_dirty_\(round)"

            // Phone advances both records on server.
            for (rid, body) in [(dirtyId, remoteBodyDirty), (cleanId, remoteBodyClean)] {
                let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: 1, quote: "q", body: body), highlightId: nil)
                try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload)
            }
            try await phone.engine.sync()

            // Simulate user editing `dirtyId` locally right before pullAll executes (e.g., edit arrives while sync is between push and pull).
            let dirtyPayload = RecordAdapter.notePayload(NoteEntry(id: dirtyId, page: 1, quote: "q", body: localDirtyBody), highlightId: nil)
            mac.transport.onBeforePull = {
                try? enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: dirtyId, payload: dirtyPayload)
            }

            try await mac.engine.sync()
            checkClientInvariants(node: &mac, context: "\(SyncFormalConfig.tag(seed, caseIndex: round))")

            // Dirty local record MUST NOT have been overwritten by pull!
            let dirtyLocal = try XCTUnwrap(mac.engine.store.record(bookId: bookId, kind: .note, recordId: dirtyId))
            XCTAssertTrue(dirtyLocal.dirty, "\(SyncFormalConfig.tag(seed, caseIndex: round)) pull cleared dirty flag on \(dirtyId)")
            let dirtyObj = try XCTUnwrap(dirtyLocal.payloadJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            XCTAssertEqual(
                dirtyObj["body"] as? String, localDirtyBody,
                "\(SyncFormalConfig.tag(seed, caseIndex: round)) pull overwrote dirty local record \(dirtyId)!"
            )

            // Meanwhile clean record MUST have updated from remote pull.
            let cleanLocal = try XCTUnwrap(mac.engine.store.record(bookId: bookId, kind: .note, recordId: cleanId))
            XCTAssertFalse(cleanLocal.dirty)
            let cleanObj = try XCTUnwrap(cleanLocal.payloadJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            XCTAssertEqual(cleanObj["body"] as? String, remoteBodyClean)

            // Reset dirty record cleanly to server head for next round.
            let head = try XCTUnwrap(server.record(bookId: bookId, kind: .note, recordId: dirtyId))
            mac.engine.store.removeOutbox(changeIds: mac.engine.store.outbox().map(\.changeId))
            mac.engine.store.upsertRecord(LocalRecordState(
                bookId: bookId, kind: .note, recordId: dirtyId,
                serverVersion: head.version, dirty: false, deleted: head.deleted,
                payloadJSON: try head.payload.map { try JSONSerialization.data(withJSONObject: $0) }
            ))
        }
    }

    // MARK: 4. Cursor Monotonicity & ServerId Reset Invariant

    func testCursorMonotonicityAndServerIdResetRecovery() async throws {
        var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
        defer { mac.cleanup(); phone.cleanup() }

        let bookData = Data("cursor-test-book".utf8)
        let reg = try await phone.engine.api.registerBook(sha256: SHA256.hex(bookData), size: bookData.count, format: "pdf", title: "CursorBook", filename: "c.pdf", docId: "doc_cursor")
        let bookId = reg.bookId

        // Push 7 notes in waves from Phone and pull on Mac with pageSize = 2.
        for wave in 0..<3 {
            for j in 0..<3 {
                let rid = "n_\(wave)_\(j)"
                let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: j + 1, quote: "q", body: "w\(wave)_\(j)"), highlightId: nil)
                try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload)
            }
            try await phone.engine.sync()
            try await mac.engine.sync()
            checkClientInvariants(node: &mac, context: "wave=\(wave)")
            XCTAssertEqual(mac.engine.store.cursor, server.seq)
        }

        let oldCursor = mac.engine.store.cursor
        XCTAssertGreaterThanOrEqual(oldCursor, 10)

        // Reset server to a new serverId with fresh state & 1 new record.
        server.resetServer(newServerId: "srv_2")
        let regNew = try await phone.engine.api.registerBook(sha256: SHA256.hex(bookData), size: bookData.count, format: "pdf", title: "FreshBook", filename: "c.pdf", docId: "doc_cursor")
        let freshPayload = RecordAdapter.notePayload(NoteEntry(id: "n_fresh", page: 1, quote: "fresh", body: "after reset"), highlightId: nil)
        try enqueueDirectEdit(on: phone.engine, bookId: regNew.bookId, kind: .note, recordId: "n_fresh", payload: freshPayload, overrideBaseVersion: 0)
        try await phone.engine.sync()

        try await mac.engine.sync()
        XCTAssertEqual(mac.engine.store.serverId, "srv_2")
        XCTAssertEqual(mac.engine.store.cursor, server.seq)
        XCTAssertLessThan(mac.engine.store.cursor, oldCursor, "cursor must reset for new serverId")
        XCTAssertNotNil(mac.engine.store.record(bookId: regNew.bookId, kind: .note, recordId: "n_fresh"))
        XCTAssertNil(mac.engine.store.record(bookId: bookId, kind: .note, recordId: "n_0_0"), "old server records must be cleared on serverId reset")
    }

    // MARK: 5. Disk Full on Book Blob Never Blocks Record Sync

    func testDiskFullOnBlobNeverBlocksRecordPushOrPull() async throws {
        var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
        defer { mac.cleanup(); phone.cleanup() }

        server.diskFull = true
        let bookData = Data("large-book-payload-for-disk-full-test".utf8)
        let snapshot1 = BookSyncSnapshot(
            fileURL: URL(fileURLWithPath: "/tmp/DiskFull.pdf"),
            fileData: bookData,
            format: "pdf",
            title: "DiskFull Book",
            docId: "doc_df",
            highlights: [HighlightEntry(id: "h_df1", color: 2, page: 1, quote: "quote 1", noteID: "h_df1")],
            notes: [NoteEntry(id: "h_df1", page: 1, quote: "quote 1", body: "note while disk full")],
            words: [WordEntry(id: RecordAdapter.wordId(for: "epistemology"), word: "epistemology", definition: "study of knowledge", lookups: [])],
            isPDF: true,
            page: 1,
            pdfPoint: nil,
            cfi: nil
        )

        try await mac.engine.sync(snapshot: snapshot1)
        checkClientInvariants(node: &mac, context: "diskFull-initial")

        XCTAssertTrue(mac.engine.store.storageFull)
        XCTAssertEqual(mac.engine.store.waitingBookCount(), 1)
        XCTAssertEqual(mac.engine.status().state, .storageFull)
        XCTAssertFalse(server.hasBlob(sha256: snapshot1.sha256))

        let bookId = try XCTUnwrap(mac.engine.store.bookId(forSha256: snapshot1.sha256))
        // Records MUST have pushed despite 507 on blob PUT.
        XCTAssertEqual(server.record(bookId: bookId, kind: .note, recordId: "h_df1")?.payload?["body"] as? String, "note while disk full")
        XCTAssertNotNil(server.record(bookId: bookId, kind: .highlight, recordId: "h_df1"))
        XCTAssertNotNil(server.record(bookId: bookId, kind: .word, recordId: "w_epistemology"))

        // Phone pulls Mac's records AND pushes back an edit while server is STILL disk_full.
        try await phone.engine.sync()
        XCTAssertNotNil(phone.engine.store.record(bookId: bookId, kind: .note, recordId: "h_df1"))
        let phoneNote = RecordAdapter.notePayload(NoteEntry(id: "n_phone_df", page: 2, quote: "phone q", body: "from phone under disk full"), highlightId: nil)
        try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: "n_phone_df", payload: phoneNote)
        try await phone.engine.sync()

        // Mac pulls Phone's record AND pushes another note update while STILL disk_full.
        var snapshot2 = snapshot1
        snapshot2.notes = [NoteEntry(id: "h_df1", page: 1, quote: "quote 1", body: "second edit while disk full")]
        try await mac.engine.sync(snapshot: snapshot2)
        checkClientInvariants(node: &mac, context: "diskFull-second")

        XCTAssertEqual(server.record(bookId: bookId, kind: .note, recordId: "h_df1")?.payload?["body"] as? String, "second edit while disk full")
        XCTAssertNotNil(mac.engine.store.record(bookId: bookId, kind: .note, recordId: "n_phone_df"))
        XCTAssertTrue(mac.engine.store.storageFull)

        // Space freed -> next ingest/sync uploads the blob and clears storageFull!
        server.diskFull = false
        try await mac.engine.sync(snapshot: snapshot2)
        checkClientInvariants(node: &mac, context: "diskFull-recovered")
        XCTAssertTrue(server.hasBlob(sha256: snapshot1.sha256))
        XCTAssertFalse(mac.engine.store.storageFull)
        XCTAssertEqual(mac.engine.store.waitingBookCount(), 0)
        XCTAssertEqual(mac.engine.status().state, .synced)
    }

    // MARK: 6. Dropped Push Response + Transient 503 Idempotent Retry & Convergence

    func testDroppedPushResponseAndTransient503ConvergeIdempotently() async throws {
        let seed = SyncFormalConfig.seed ^ 0x12
        var rng = SplitMix64(seed: seed)
        var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
        defer { mac.cleanup(); phone.cleanup() }

        let bookData = Data("drop-retry-book".utf8)
        let reg = try await mac.engine.api.registerBook(sha256: SHA256.hex(bookData), size: bookData.count, format: "pdf", title: "RetryBook", filename: "r.pdf", docId: "doc_retry")
        let bookId = reg.bookId

        for round in 0..<min(SyncFormalConfig.cases, 20) {
            let rid = "n_\(round % 4)"
            let body = "retry_body_\(round)_\(rng.nextInt(in: 0...9999))"
            let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: 1, quote: "q", body: body), highlightId: nil)
            try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload)

            let expectedVersion = (server.record(bookId: bookId, kind: .note, recordId: rid)?.version ?? 0) + 1
            mac.transport.dropNextPushResponse = true

            do {
                try await mac.engine.sync()
                XCTFail("\(SyncFormalConfig.tag(seed, caseIndex: round)) expected dropped-response network error")
            } catch let err as SyncAPIError {
                XCTAssertTrue(err.isNetwork)
            }

            // Server committed the change, while Mac kept outbox intact.
            XCTAssertEqual(server.record(bookId: bookId, kind: .note, recordId: rid)?.version, expectedVersion)
            XCTAssertEqual(mac.engine.store.outbox().count, 1)

            // Inject transient 503 before successful retry.
            mac.transport.transient503Count = 1
            _ = try? await mac.engine.sync()

            // Now retry succeeds idempotently (no double version bump, no bogus conflict).
            try await mac.engine.sync()
            try await phone.engine.sync()
            checkClientInvariants(node: &mac, context: "\(SyncFormalConfig.tag(seed, caseIndex: round))")
            checkClientInvariants(node: &phone, context: "\(SyncFormalConfig.tag(seed, caseIndex: round))")

            XCTAssertEqual(server.record(bookId: bookId, kind: .note, recordId: rid)?.version, expectedVersion, "idempotent replay must not double-bump version")
            XCTAssertEqual(server.openConflictCount(), 0)
            XCTAssertEqual(mac.engine.store.record(bookId: bookId, kind: .note, recordId: rid)?.serverVersion, expectedVersion)
            XCTAssertEqual(phone.engine.store.record(bookId: bookId, kind: .note, recordId: rid)?.serverVersion, expectedVersion)
            XCTAssertEqual(
                CanonicalJSON.stringifyData(mac.engine.store.record(bookId: bookId, kind: .note, recordId: rid)?.payloadJSON),
                CanonicalJSON.stringifyData(phone.engine.store.record(bookId: bookId, kind: .note, recordId: rid)?.payloadJSON)
            )
        }
    }

    // MARK: 7. CRITICAL CHECK: SyncEngine.resolve Stale serverVersion Bug Witness

    func testResolveConflictUpdatesLocalServerVersionToServerHeadPlusOne() async throws {
        // Tests BOTH head = baseVersion + 1 (base=1, head=2 -> resolved=3)
        // AND head = baseVersion + 2 (base=1, head=3 -> resolved=4).
        for extraFastForwards in [1, 2] {
            var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 5)
            defer { mac.cleanup(); phone.cleanup() }

            let bookData = Data("resolve-version-book-\(extraFastForwards)".utf8)
            let reg = try await mac.engine.api.registerBook(
                sha256: SHA256.hex(bookData),
                size: bookData.count,
                format: "pdf",
                title: "ResolveBook",
                filename: "resolve.pdf",
                docId: "doc_resolve_\(extraFastForwards)"
            )
            let bookId = reg.bookId
            let noteId = "n_conflict"

            // Step 1: Mac creates note at v1; Phone pulls v1.
            let v1Payload = RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "v1"), highlightId: nil)
            try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: noteId, payload: v1Payload)
            try await mac.engine.sync()
            try await phone.engine.sync()
            XCTAssertEqual(server.record(bookId: bookId, kind: .note, recordId: noteId)?.version, 1)

            // Step 2: Mac fast-forwards 1 or 2 times (server head becomes version 2 or 3).
            for ff in 1...extraFastForwards {
                let p = RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "mac_v\(1 + ff)"), highlightId: nil)
                try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: noteId, payload: p)
                try await mac.engine.sync()
            }
            let headBeforeConflict = 1 + extraFastForwards
            XCTAssertEqual(server.record(bookId: bookId, kind: .note, recordId: noteId)?.version, headBeforeConflict)

            // Step 3: Phone edits from stale baseVersion = 1 and syncs -> opens conflict with baseVersion=1, head=headBeforeConflict.
            let phonePayload = RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "phone_diverged"), highlightId: nil)
            try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: noteId, payload: phonePayload)
            try await phone.engine.sync()

            // Step 4: Mac pulls the open conflict.
            try await mac.engine.sync()
            let conflict = try XCTUnwrap(mac.engine.conflicts().first(where: { $0.recordId == noteId }))
            XCTAssertEqual(conflict.baseVersion, 1)

            // Step 5: Mac resolves conflict. Server writes version = headBeforeConflict + 1 (3 or 4).
            try await mac.engine.resolve(conflict: conflict, choice: .combineNotes(body: "merged_body"))

            let serverAfterResolve = try XCTUnwrap(server.record(bookId: bookId, kind: .note, recordId: noteId))
            let expectedResolvedVersion = headBeforeConflict + 1
            XCTAssertEqual(serverAfterResolve.version, expectedResolvedVersion)
            XCTAssertEqual(server.openConflictCount(), 0)

            // CRITICAL INVARIANT A: Local SyncStore serverVersion MUST match server's authoritative head+1, NOT conflict.baseVersion + 1!
            let macLocalAfterResolve = try XCTUnwrap(mac.engine.store.record(bookId: bookId, kind: .note, recordId: noteId))
            XCTAssertEqual(
                macLocalAfterResolve.serverVersion,
                expectedResolvedVersion,
                "SyncEngine.resolve recorded stale local serverVersion=\(macLocalAfterResolve.serverVersion) (conflict.baseVersion+1=\(conflict.baseVersion + 1)) instead of server head+1=\(expectedResolvedVersion) (conflict.baseVersion=\(conflict.baseVersion), pre-resolve head=\(headBeforeConflict))"
            )

            // CRITICAL INVARIANT B: VaultWriter envelope MUST carry server head+1, NOT conflict.baseVersion + 1.
            let projectedEnvelope = try XCTUnwrap(mac.vaultWriter.allEnvelopes.last(where: { $0.recordId == noteId }))
            XCTAssertEqual(
                projectedEnvelope.version,
                expectedResolvedVersion,
                "SyncEngine.resolve projected envelope with stale version=\(projectedEnvelope.version) instead of \(expectedResolvedVersion)"
            )

            // CRITICAL INVARIANT C: Subsequent local edit by Mac before any pull MUST fast-forward cleanly without re-opening a bogus conflict!
            let followUpPayload = RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "mac_follow_up_after_resolve"), highlightId: nil)
            try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: noteId, payload: followUpPayload)
            try await mac.engine.sync()
            checkClientInvariants(node: &mac, context: "resolve-followup-ff=\(extraFastForwards)")

            XCTAssertEqual(
                server.openConflictCount(), 0,
                "Subsequent edit after SyncEngine.resolve re-opened a bogus conflict because local serverVersion was stale!"
            )
            XCTAssertEqual(
                server.record(bookId: bookId, kind: .note, recordId: noteId)?.version,
                expectedResolvedVersion + 1,
                "Subsequent edit after resolve failed to fast-forward to v\(expectedResolvedVersion + 1)"
            )
            XCTAssertEqual(
                server.record(bookId: bookId, kind: .note, recordId: noteId)?.payload?["body"] as? String,
                "mac_follow_up_after_resolve"
            )
        }
    }

    // MARK: 8. Remotely Resolved Conflict Clears on Peer Pull Witness

    func testRemotelyResolvedConflictClearsOnPeerPull() async throws {
        let (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 5)
        defer { mac.cleanup(); phone.cleanup() }

        let bookData = Data("peer-conflict-clear-book".utf8)
        let reg = try await mac.engine.api.registerBook(sha256: SHA256.hex(bookData), size: bookData.count, format: "pdf", title: "PeerBook", filename: "p.pdf", docId: "doc_peer")
        let bookId = reg.bookId
        let noteId = "n_peer"

        try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: noteId, payload: RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "v1"), highlightId: nil))
        try await mac.engine.sync()
        try await phone.engine.sync()

        try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: noteId, payload: RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "mac_v2"), highlightId: nil))
        try await mac.engine.sync()

        try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: noteId, payload: RecordAdapter.notePayload(NoteEntry(id: noteId, page: 1, quote: "q", body: "phone_v2"), highlightId: nil))
        try await phone.engine.sync()
        try await mac.engine.sync()

        // Both Mac and Phone now have the open conflict saved locally.
        XCTAssertEqual(phone.engine.conflicts().count, 1)
        let conflict = try XCTUnwrap(mac.engine.conflicts().first)

        // Mac resolves the conflict on the server.
        try await mac.engine.resolve(conflict: conflict, choice: .keepSide(0))
        XCTAssertEqual(server.openConflictCount(), 0)

        // Phone pulls -> its locally cached conflict MUST be cleared once the server resolves it!
        try await phone.engine.sync()
        XCTAssertEqual(
            phone.engine.conflicts().count, 0,
            "Peer SyncEngine kept stale resolved conflict(s) in SyncStore after pulling resolved head and empty GET /v1/conflicts: \(phone.engine.conflicts().map(\.conflictId))"
        )
    }

    // MARK: 9. Mid-Pull ServerId Rotation Termination Witness

    func testServerIdRotationMidPullTerminatesWithoutInfiniteLoop() async throws {
        let (_, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
        defer { mac.cleanup(); phone.cleanup() }

        // Initial sync establishes serverId = "srv_1".
        try await mac.engine.sync()
        XCTAssertEqual(mac.engine.store.serverId, "srv_1")

        // Rotate serverId right after GET /v1/health succeeds, when GET /v1/changes arrives.
        mac.transport.pullCalls = 0
        mac.transport.maxPullCallsInWindow = 10
        mac.transport.rotateServerIdOnNextPullTo = "srv_rotated_mid_pull"

        try await mac.engine.sync()
        XCTAssertEqual(mac.engine.store.serverId, "srv_rotated_mid_pull")
        XCTAssertLessThanOrEqual(
            mac.transport.pullCalls, 4,
            "pullAll must update expected serverId and terminate cleanly after mid-pull serverId rotation"
        )
    }

    // MARK: 10. Randomized Two-Device Fault-Injection Convergence (Disjoint-Owner / Serialized Edits)

    func testStatefulTwoDeviceFaultInjectionConvergenceOnDisjointKeys() async throws {
        // Exercises randomized offline periods, dropped push responses, transient 503s, disk_full on blobs,
        // deletes, highlights/notes/words/positions, and paginated pulls across 2 real SQLite SyncEngines
        // without triggering the known SyncEngine conflict-resolution bugs.
        let baseSeed = SyncFormalConfig.seed ^ 0x14
        let schedules = min(SyncFormalConfig.cases, 15)

        for scheduleIdx in 0..<schedules {
            let scheduleSeed = baseSeed &+ UInt64(scheduleIdx) &* 0x9E37_79B9
            var rng = SplitMix64(seed: scheduleSeed)
            var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
            defer { mac.cleanup(); phone.cleanup() }

            let bookData = Data("converge-book-\(scheduleIdx)".utf8)
            let sha = SHA256.hex(bookData)
            let reg = try await mac.engine.api.registerBook(sha256: sha, size: bookData.count, format: "pdf", title: "ConvBook", filename: "cv.pdf", docId: "doc_cv_\(scheduleIdx)")
            let bookId = reg.bookId
            mac.engine.store.rememberBook(sha256: sha, bookId: bookId, format: "pdf", title: "ConvBook", filename: "cv.pdf", docId: "doc_cv_\(scheduleIdx)", size: bookData.count, waitingForSpace: false)

            let macNotes = ["n_mac_0", "n_mac_1"]
            let phoneNotes = ["n_phone_0", "n_phone_1"]
            var macPendingDrop = false
            var phonePendingDrop = false

            for step in 0..<24 {
                let action = rng.nextInt(in: 0...7)
                switch action {
                case 0, 1:
                    // Only mutate Mac outbox when not awaiting an idempotent replay of a dropped batch.
                    guard !macPendingDrop else { continue }
                    let rid = rng.pick(macNotes)
                    let del = rng.nextBool(probabilityTrue: 0.2)
                    let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: step + 1, quote: "mq", body: "m_\(step)"), highlightId: nil)
                    try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload, deleted: del)
                case 2, 3:
                    guard !phonePendingDrop else { continue }
                    let rid = rng.pick(phoneNotes)
                    let del = rng.nextBool(probabilityTrue: 0.2)
                    let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: step + 1, quote: "pq", body: "p_\(step)"), highlightId: nil)
                    try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload, deleted: del)
                case 4:
                    let drop = !macPendingDrop && !mac.engine.store.outbox().isEmpty && rng.nextBool(probabilityTrue: 0.3)
                    let offline = !drop && rng.nextBool(probabilityTrue: 0.15)
                    mac.transport.dropNextPushResponse = drop
                    mac.transport.offline = offline
                    do {
                        try await mac.engine.sync()
                        macPendingDrop = false
                    } catch {
                        if drop { macPendingDrop = true }
                    }
                    mac.transport.offline = false
                    mac.transport.dropNextPushResponse = false
                case 5:
                    let drop = !phonePendingDrop && !phone.engine.store.outbox().isEmpty && rng.nextBool(probabilityTrue: 0.3)
                    let offline = !drop && rng.nextBool(probabilityTrue: 0.15)
                    phone.transport.dropNextPushResponse = drop
                    phone.transport.offline = offline
                    do {
                        try await phone.engine.sync()
                        phonePendingDrop = false
                    } catch {
                        if drop { phonePendingDrop = true }
                    }
                    phone.transport.offline = false
                    phone.transport.dropNextPushResponse = false
                case 6:
                    server.diskFull = rng.nextBool()
                    if !macPendingDrop {
                        let snap = BookSyncSnapshot(
                            fileURL: URL(fileURLWithPath: "/tmp/ConvBook.pdf"),
                            fileData: bookData,
                            format: "pdf",
                            title: "ConvBook",
                            docId: "doc_cv_\(scheduleIdx)",
                            highlights: [],
                            notes: [],
                            words: [],
                            isPDF: true,
                            page: step + 1,
                            pdfPoint: nil,
                            cfi: nil
                        )
                        _ = try? await mac.engine.sync(snapshot: snap)
                    }
                default:
                    guard !phonePendingDrop else { continue }
                    let posId = RecordAdapter.positionId(bookId: bookId, deviceId: phone.engine.macDeviceId)
                    let posPayload = RecordAdapter.positionPayload(bookId: bookId, deviceId: phone.engine.macDeviceId, isPDF: true, page: step + 1, point: nil, cfi: nil)
                    try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .position, recordId: posId, payload: posPayload)
                }

                checkClientInvariants(node: &mac, context: "\(SyncFormalConfig.tag(scheduleSeed, caseIndex: scheduleIdx)) step=\(step)")
                checkClientInvariants(node: &phone, context: "\(SyncFormalConfig.tag(scheduleSeed, caseIndex: scheduleIdx)) step=\(step)")
            }

            server.diskFull = false
            mac.transport.offline = false
            phone.transport.offline = false
            mac.transport.dropNextPushResponse = false
            phone.transport.dropNextPushResponse = false

            try await mac.engine.sync()
            try await phone.engine.sync()
            try await mac.engine.sync()

            let ctx = SyncFormalConfig.tag(scheduleSeed, caseIndex: scheduleIdx)
            XCTAssertTrue(mac.engine.store.outbox().isEmpty, "\(ctx) Mac outbox not empty")
            XCTAssertTrue(phone.engine.store.outbox().isEmpty, "\(ctx) Phone outbox not empty")
            XCTAssertEqual(server.openConflictCount(), 0, "\(ctx) unexpected open conflict")

            for (key, head) in server.allClientRecords() {
                let mRec = mac.engine.store.record(bookId: key.bookId, kind: key.kind, recordId: key.recordId)
                let pRec = phone.engine.store.record(bookId: key.bookId, kind: key.kind, recordId: key.recordId)
                XCTAssertEqual(mRec?.serverVersion, head.version, "\(ctx) Mac version mismatch \(key)")
                XCTAssertEqual(pRec?.serverVersion, head.version, "\(ctx) Phone version mismatch \(key)")
                XCTAssertEqual(mRec?.deleted, head.deleted, "\(ctx) Mac deleted mismatch \(key)")
                XCTAssertEqual(pRec?.deleted, head.deleted, "\(ctx) Phone deleted mismatch \(key)")
                XCTAssertEqual(CanonicalJSON.stringifyData(mRec?.payloadJSON), CanonicalJSON.stringify(head.payload), "\(ctx) Mac payload mismatch \(key)")
                XCTAssertEqual(CanonicalJSON.stringifyData(pRec?.payloadJSON), CanonicalJSON.stringify(head.payload), "\(ctx) Phone payload mismatch \(key)")
            }
        }
    }

    // MARK: 11. Full Randomized Stateful Two-Device Model-Based Harness (With Concurrent Conflicts & Resolve)

    func testStatefulTwoDeviceModelConformanceWithFaultInjection() async throws {
        let baseSeed = SyncFormalConfig.seed ^ 0x13
        let schedules = min(SyncFormalConfig.cases, 15)

        for scheduleIdx in 0..<schedules {
            let scheduleSeed = baseSeed &+ UInt64(scheduleIdx) &* 0x9E37_79B9
            var rng = SplitMix64(seed: scheduleSeed)
            var (server, mac, phone) = try await makeTwoDeviceCluster(pageSize: 2)
            defer { mac.cleanup(); phone.cleanup() }

            let bookData = Data("stateful-book-\(scheduleIdx)".utf8)
            let sha = SHA256.hex(bookData)
            let reg = try await mac.engine.api.registerBook(sha256: sha, size: bookData.count, format: "pdf", title: "ModelBook", filename: "m.pdf", docId: "doc_m_\(scheduleIdx)")
            let bookId = reg.bookId
            mac.engine.store.rememberBook(sha256: sha, bookId: bookId, format: "pdf", title: "ModelBook", filename: "m.pdf", docId: "doc_m_\(scheduleIdx)", size: bookData.count, waitingForSpace: false)

            let recordIds = ["n_0", "n_1", "n_2"]
            var trace: [String] = []
            let steps = 20

            for step in 0..<steps {
                let action = rng.nextInt(in: 0...9)
                switch action {
                case 0, 1:
                    // Local edit on Mac
                    let rid = rng.pick(recordIds)
                    let deleted = rng.nextBool(probabilityTrue: 0.15)
                    let body = "mac_s\(step)"
                    let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: 1, quote: "q", body: body), highlightId: nil)
                    try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload, deleted: deleted)
                    trace.append("step \(step): mac.edit(\(rid), del=\(deleted), body=\(body))")
                case 2, 3:
                    // Local edit on Phone
                    let rid = rng.pick(recordIds)
                    let deleted = rng.nextBool(probabilityTrue: 0.15)
                    let body = "phone_s\(step)"
                    let payload = RecordAdapter.notePayload(NoteEntry(id: rid, page: 1, quote: "q", body: body), highlightId: nil)
                    try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .note, recordId: rid, payload: payload, deleted: deleted)
                    trace.append("step \(step): phone.edit(\(rid), del=\(deleted), body=\(body))")
                case 4:
                    // Sync Mac (possibly with dropped response or offline)
                    let drop = rng.nextBool(probabilityTrue: 0.25)
                    let offline = !drop && rng.nextBool(probabilityTrue: 0.15)
                    mac.transport.dropNextPushResponse = drop
                    mac.transport.offline = offline
                    trace.append("step \(step): mac.sync(drop=\(drop), offline=\(offline))")
                    _ = try? await mac.engine.sync()
                    mac.transport.offline = false
                    mac.transport.dropNextPushResponse = false
                case 5:
                    // Sync Phone (possibly with dropped response or offline)
                    let drop = rng.nextBool(probabilityTrue: 0.25)
                    let offline = !drop && rng.nextBool(probabilityTrue: 0.15)
                    phone.transport.dropNextPushResponse = drop
                    phone.transport.offline = offline
                    trace.append("step \(step): phone.sync(drop=\(drop), offline=\(offline))")
                    _ = try? await phone.engine.sync()
                    phone.transport.offline = false
                    phone.transport.dropNextPushResponse = false
                case 6:
                    // Toggle diskFull and ingest book on Mac
                    let full = rng.nextBool(probabilityTrue: 0.5)
                    server.diskFull = full
                    let snap = BookSyncSnapshot(
                        fileURL: URL(fileURLWithPath: "/tmp/ModelBook.pdf"),
                        fileData: bookData,
                        format: "pdf",
                        title: "ModelBook",
                        docId: "doc_m_\(scheduleIdx)",
                        highlights: [],
                        notes: [],
                        words: [],
                        isPDF: true,
                        page: step + 1,
                        pdfPoint: nil,
                        cfi: nil
                    )
                    trace.append("step \(step): mac.sync(snapshot, diskFull=\(full))")
                    _ = try? await mac.engine.sync(snapshot: snap)
                case 7:
                    // Resolve open conflict on Mac (if any)
                    if let conflict = mac.engine.conflicts().first {
                        let choice: ConflictChoice = rng.nextBool()
                            ? .keepSide(rng.nextInt(in: 0...(conflict.sides.count - 1)))
                            : .combineNotes(body: "resolved_s\(step)")
                        trace.append("step \(step): mac.resolve(\(conflict.conflictId), base=\(conflict.baseVersion))")
                        _ = try? await mac.engine.resolve(conflict: conflict, choice: choice)
                    }
                case 8:
                    // Mac pushes own position
                    let posId = RecordAdapter.positionId(bookId: bookId, deviceId: mac.engine.macDeviceId)
                    let posPayload = RecordAdapter.positionPayload(bookId: bookId, deviceId: mac.engine.macDeviceId, isPDF: true, page: step + 1, point: nil, cfi: nil)
                    try enqueueDirectEdit(on: mac.engine, bookId: bookId, kind: .position, recordId: posId, payload: posPayload)
                    trace.append("step \(step): mac.position(page=\(step + 1))")
                default:
                    // Phone pushes own position
                    let posId = RecordAdapter.positionId(bookId: bookId, deviceId: phone.engine.macDeviceId)
                    let posPayload = RecordAdapter.positionPayload(bookId: bookId, deviceId: phone.engine.macDeviceId, isPDF: true, page: step + 10, point: nil, cfi: nil)
                    try enqueueDirectEdit(on: phone.engine, bookId: bookId, kind: .position, recordId: posId, payload: posPayload)
                    trace.append("step \(step): phone.position(page=\(step + 10))")
                }

                // Check step invariants on both devices.
                checkClientInvariants(node: &mac, context: "\(SyncFormalConfig.tag(scheduleSeed, caseIndex: scheduleIdx)) step=\(step)")
                checkClientInvariants(node: &phone, context: "\(SyncFormalConfig.tag(scheduleSeed, caseIndex: scheduleIdx)) step=\(step)")
            }

            // Quiescence phase: clear faults, flush & pull both devices, resolve any open conflicts, re-sync both.
            server.diskFull = false
            mac.transport.offline = false
            phone.transport.offline = false
            mac.transport.dropNextPushResponse = false
            phone.transport.dropNextPushResponse = false

            let ctx = "\(SyncFormalConfig.tag(scheduleSeed, caseIndex: scheduleIdx)) quiescence\nTrace:\n\(trace.joined(separator: "\n"))"
            do {
                try await mac.engine.sync()
                try await phone.engine.sync()
                try await mac.engine.sync()

                for conflict in mac.engine.conflicts() {
                    try await mac.engine.resolve(conflict: conflict, choice: .keepSide(0))
                }
                try await mac.engine.sync()
                try await phone.engine.sync()
                try await mac.engine.sync()
            } catch {
                XCTFail("\(ctx)\nQuiescence sync/resolve threw unexpected error: \(error)")
                return
            }

            checkClientInvariants(node: &mac, context: ctx)
            checkClientInvariants(node: &phone, context: ctx)

            XCTAssertTrue(mac.engine.store.outbox().isEmpty, "\(ctx)\nMac outbox not empty at quiescence")
            XCTAssertTrue(phone.engine.store.outbox().isEmpty, "\(ctx)\nPhone outbox not empty at quiescence")
            XCTAssertEqual(server.openConflictCount(), 0, "\(ctx)\nServer still has open conflicts")
            XCTAssertEqual(mac.engine.conflicts().count, 0, "\(ctx)\nMac still has open conflicts")
            XCTAssertEqual(phone.engine.conflicts().count, 0, "\(ctx)\nPhone still has stale open conflicts")

            // Convergence: every client record on the server must match BOTH Mac and Phone clean local state.
            for (key, head) in server.allClientRecords() {
                let macRec = mac.engine.store.record(bookId: key.bookId, kind: key.kind, recordId: key.recordId)
                let phoneRec = phone.engine.store.record(bookId: key.bookId, kind: key.kind, recordId: key.recordId)

                XCTAssertNotNil(macRec, "\(ctx)\nMac missing record \(key)")
                XCTAssertNotNil(phoneRec, "\(ctx)\nPhone missing record \(key)")

                XCTAssertEqual(macRec?.dirty, false, "\(ctx)\nMac record \(key) still dirty")
                XCTAssertEqual(phoneRec?.dirty, false, "\(ctx)\nPhone record \(key) still dirty")

                XCTAssertEqual(macRec?.serverVersion, head.version, "\(ctx)\nMac version mismatch for \(key)")
                XCTAssertEqual(phoneRec?.serverVersion, head.version, "\(ctx)\nPhone version mismatch for \(key)")

                XCTAssertEqual(macRec?.deleted, head.deleted, "\(ctx)\nMac deleted mismatch for \(key)")
                XCTAssertEqual(phoneRec?.deleted, head.deleted, "\(ctx)\nPhone deleted mismatch for \(key)")

                let expectedJSON = CanonicalJSON.stringify(head.payload)
                XCTAssertEqual(CanonicalJSON.stringifyData(macRec?.payloadJSON), expectedJSON, "\(ctx)\nMac payload diverged for \(key)")
                XCTAssertEqual(CanonicalJSON.stringifyData(phoneRec?.payloadJSON), expectedJSON, "\(ctx)\nPhone payload diverged for \(key)")
            }
        }
    }
}
