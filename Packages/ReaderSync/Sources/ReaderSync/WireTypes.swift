import Foundation
import ReaderCore

public enum RecordKind: String, Equatable, Sendable, CaseIterable {
    case book, highlight, note, word, lookup, position
}

public struct HealthResponse: Equatable, Sendable {
    public var ok: Bool
    public var serverId: String
    public var serverVersion: String
    public var protocolVersion: Int
    public var seq: Int

    public init(ok: Bool, serverId: String, serverVersion: String, protocolVersion: Int, seq: Int) {
        self.ok = ok
        self.serverId = serverId
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.seq = seq
    }

    public static func parse(_ data: Data) throws -> HealthResponse {
        let object = try JSONSupport.object(from: data)
        return HealthResponse(
            ok: object.bool("ok") ?? false,
            serverId: object.string("serverId") ?? "",
            serverVersion: object.string("serverVersion") ?? "",
            protocolVersion: object.int("protocol") ?? 0,
            seq: object.int("seq") ?? 0
        )
    }
}

public struct IssuedPairingToken: Equatable, Sendable {
    public var token: String
    public var expiresAt: Date
    public var qr: String

    public var pairingQR: PairingQR? { try? PairingQR.parse(qr) }

    public static func parse(_ data: Data) throws -> IssuedPairingToken {
        let object = try JSONSupport.object(from: data)
        guard let token = object.string("token"), let qr = object.string("qr") else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "pairing token response is missing fields")
        }
        return IssuedPairingToken(token: token, expiresAt: parseDate(object.string("expiresAt")) ?? Date().addingTimeInterval(600), qr: qr)
    }
}

public struct RedeemResponse: Equatable, Sendable {
    public var deviceId: String
    public var credential: String
    public var serverId: String
    public var kind: String

    public static func parse(_ data: Data) throws -> RedeemResponse {
        let object = try JSONSupport.object(from: data)
        guard let deviceId = object.string("deviceId"),
              let credential = object.string("credential"),
              let serverId = object.string("serverId"),
              let kind = object.string("kind") else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "redeem response is missing fields")
        }
        return RedeemResponse(deviceId: deviceId, credential: credential, serverId: serverId, kind: kind)
    }
}

public struct PairedDevice: Equatable, Sendable, Identifiable {
    public var deviceId: String
    public var name: String
    public var platform: String
    public var kind: String
    public var createdAt: Date?
    public var lastSeenAt: Date?
    public var revoked: Bool

    public var id: String { deviceId }

    public var isPhone: Bool { kind == "phone" }
    public var isMac: Bool { kind == "mac" }

    public static func parseList(_ data: Data) throws -> [PairedDevice] {
        let object = try JSONSupport.object(from: data)
        let items = object["devices"] as? [Any] ?? []
        return items.compactMap { item in
            guard let row = item as? [String: Any], let deviceId = row.string("deviceId") else { return nil }
            return PairedDevice(
                deviceId: deviceId,
                name: row.string("name") ?? deviceId,
                platform: row.string("platform") ?? "",
                kind: row.string("kind") ?? "",
                createdAt: parseDate(row.string("createdAt")),
                lastSeenAt: parseDate(row.string("lastSeenAt")),
                revoked: row.bool("revoked") ?? false
            )
        }
    }
}

public struct PushChange: Sendable {
    public var changeId: String
    public var bookId: String
    public var kind: RecordKind
    public var recordId: String
    public var baseVersion: Int
    public var deleted: Bool
    public var clientTime: String?
    public var payload: [String: Any]?

    public init(changeId: String, bookId: String, kind: RecordKind, recordId: String, baseVersion: Int, deleted: Bool, clientTime: String?, payload: [String: Any]?) {
        self.changeId = changeId
        self.bookId = bookId
        self.kind = kind
        self.recordId = recordId
        self.baseVersion = baseVersion
        self.deleted = deleted
        self.clientTime = clientTime
        self.payload = payload
    }

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "changeId": changeId,
            "bookId": bookId,
            "kind": kind.rawValue,
            "id": recordId,
            "baseVersion": baseVersion,
            "deleted": deleted,
        ]
        if let clientTime { object["clientTime"] = clientTime }
        if let payload {
            object["payload"] = payload
        } else {
            object["payload"] = NSNull()
        }
        return object
    }
}

public struct ChangeResult: Equatable, Sendable {
    public var changeId: String
    public var status: String
    public var version: Int?
    public var seq: Int?
    public var conflictId: String?
    public var errorCode: String?
    public var errorMessage: String?

    public var isApplied: Bool { status == "applied" || status == "noop" }
    public var isConflict: Bool { status == "conflict" }

    public static func parse(_ object: [String: Any]) -> ChangeResult? {
        guard let changeId = object.string("changeId"), let status = object.string("status") else { return nil }
        let error = object["error"] as? [String: Any]
        return ChangeResult(
            changeId: changeId,
            status: status,
            version: object.int("version"),
            seq: object.int("seq"),
            conflictId: object.string("conflictId"),
            errorCode: error?.string("code"),
            errorMessage: error?.string("message")
        )
    }
}

public struct PushResponse: Equatable, Sendable {
    public var batchId: String
    public var seq: Int
    public var results: [ChangeResult]

    public static func parse(_ data: Data) throws -> PushResponse {
        let object = try JSONSupport.object(from: data)
        let results = (object["results"] as? [Any] ?? []).compactMap { item in
            (item as? [String: Any]).flatMap(ChangeResult.parse)
        }
        return PushResponse(batchId: object.string("batchId") ?? "", seq: object.int("seq") ?? 0, results: results)
    }
}

public struct ConflictSide: Sendable {
    public var changeId: String
    public var deviceId: String
    public var version: Int?
    public var deleted: Bool
    public var payload: [String: Any]?
    public var clientTime: String?

    public init(changeId: String, deviceId: String, version: Int?, deleted: Bool, payload: [String: Any]?, clientTime: String?) {
        self.changeId = changeId
        self.deviceId = deviceId
        self.version = version
        self.deleted = deleted
        self.payload = payload
        self.clientTime = clientTime
    }

    public static func parse(_ object: [String: Any]) -> ConflictSide {
        let payload: [String: Any]?
        if object["payload"] is NSNull {
            payload = nil
        } else {
            payload = object["payload"] as? [String: Any]
        }
        return ConflictSide(
            changeId: object.string("changeId") ?? "",
            deviceId: object.string("deviceId") ?? "",
            version: object.int("version"),
            deleted: object.bool("deleted") ?? false,
            payload: payload,
            clientTime: object.string("clientTime")
        )
    }
}

public struct OpenConflict: Sendable, Identifiable {
    public var conflictId: String
    public var bookId: String
    public var kind: RecordKind
    public var recordId: String
    public var baseVersion: Int
    public var baseDeleted: Bool?
    public var basePayload: [String: Any]?
    public var sides: [ConflictSide]
    public var openedSeq: Int?

    public var id: String { conflictId }

    public init(
        conflictId: String,
        bookId: String,
        kind: RecordKind,
        recordId: String,
        baseVersion: Int,
        baseDeleted: Bool?,
        basePayload: [String: Any]?,
        sides: [ConflictSide],
        openedSeq: Int?
    ) {
        self.conflictId = conflictId
        self.bookId = bookId
        self.kind = kind
        self.recordId = recordId
        self.baseVersion = baseVersion
        self.baseDeleted = baseDeleted
        self.basePayload = basePayload
        self.sides = sides
        self.openedSeq = openedSeq
    }

    public static func parse(_ object: [String: Any]) -> OpenConflict? {
        guard let conflictId = object.string("conflictId") else { return nil }
        return parseWithId(conflictId, object)
    }

    private static func parseWithId(_ conflictId: String, _ object: [String: Any]) -> OpenConflict? {
        let kind = RecordKind(rawValue: object.string("kind") ?? "") ?? .highlight
        let base = object["base"] as? [String: Any]
        return OpenConflict(
            conflictId: conflictId,
            bookId: object.string("bookId") ?? "",
            kind: kind,
            recordId: object.string("id") ?? "",
            baseVersion: object.int("baseVersion") ?? 0,
            baseDeleted: base?.bool("deleted"),
            basePayload: base?["payload"] as? [String: Any],
            sides: (object["sides"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(ConflictSide.parse) },
            openedSeq: object.int("openedSeq")
        )
    }
}

public struct RecordEnvelope: Sendable {
    public var bookId: String
    public var kind: RecordKind
    public var recordId: String
    public var version: Int
    public var baseVersion: Int
    public var deleted: Bool
    public var deviceId: String?
    public var changeId: String?
    public var clientTime: String?
    public var seq: Int?
    public var payload: [String: Any]?
    public var conflict: OpenConflict?

    public static func parse(_ object: [String: Any]) -> RecordEnvelope? {
        guard let bookId = object.string("bookId"),
              let kind = RecordKind(rawValue: object.string("kind") ?? ""),
              let recordId = object.string("id") else { return nil }
        let payload: [String: Any]?
        if object["payload"] is NSNull {
            payload = nil
        } else {
            payload = object["payload"] as? [String: Any]
        }
        let conflict: OpenConflict?
        if let raw = object["conflict"] as? [String: Any] {
            conflict = OpenConflict.parse(raw)
        } else {
            conflict = nil
        }
        return RecordEnvelope(
            bookId: bookId,
            kind: kind,
            recordId: recordId,
            version: object.int("version") ?? 0,
            baseVersion: object.int("baseVersion") ?? 0,
            deleted: object.bool("deleted") ?? false,
            deviceId: object.string("deviceId"),
            changeId: object.string("changeId"),
            clientTime: object.string("clientTime"),
            seq: object.int("seq"),
            payload: payload,
            conflict: conflict
        )
    }
}

public struct PullPage: Sendable {
    public var changes: [RecordEnvelope]
    public var cursor: Int
    public var hasMore: Bool
    public var serverId: String

    public static func parse(_ data: Data) throws -> PullPage {
        let object = try JSONSupport.object(from: data)
        let changes = (object["changes"] as? [Any] ?? []).compactMap { item in
            (item as? [String: Any]).flatMap(RecordEnvelope.parse)
        }
        return PullPage(
            changes: changes,
            cursor: object.int("cursor") ?? 0,
            hasMore: object.bool("hasMore") ?? false,
            serverId: object.string("serverId") ?? ""
        )
    }
}

public struct BookRegistration: Sendable {
    public var status: String
    public var bookId: String
    public var book: RecordEnvelope?

    public static func parse(_ data: Data) throws -> BookRegistration {
        let object = try JSONSupport.object(from: data)
        let book = (object["book"] as? [String: Any]).flatMap(RecordEnvelope.parse)
        return BookRegistration(
            status: object.string("status") ?? "",
            bookId: object.string("bookId") ?? book?.bookId ?? "",
            book: book
        )
    }
}

public struct BookListItem: Equatable, Sendable {
    public var bookId: String
    public var title: String
    public var filename: String
    public var format: String
    public var docId: String?
    public var sha256: String
    public var size: Int
    public var hasBlob: Bool

    public static func parseList(_ data: Data) throws -> [BookListItem] {
        let object = try JSONSupport.object(from: data)
        let items = object["books"] as? [Any] ?? []
        return items.compactMap { item in
            guard let row = item as? [String: Any], let bookId = row.string("bookId") else { return nil }
            return BookListItem(
                bookId: bookId,
                title: row.string("title") ?? "",
                filename: row.string("filename") ?? "",
                format: row.string("format") ?? "",
                docId: row.string("docId"),
                sha256: row.string("sha256") ?? "",
                size: row.int("size") ?? 0,
                hasBlob: row.bool("hasBlob") ?? false
            )
        }
    }
}

public struct ResolveRequest: Sendable {
    public var changeId: String
    public var baseVersion: Int
    public var deleted: Bool
    public var payload: [String: Any]?

    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "changeId": changeId,
            "baseVersion": baseVersion,
            "deleted": deleted,
        ]
        if let payload {
            object["payload"] = payload
        } else {
            object["payload"] = NSNull()
        }
        return object
    }
}

func parseDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: raw)
}

func isoNow() -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.string(from: Date())
}

public func newChangeId() -> String { IDs.make("c") }
public func newBatchId() -> String { IDs.make("b") }
