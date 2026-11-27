import Foundation
import SQLite3
import ReaderCore

public struct OutboxItem: Sendable {
    public var changeId: String
    public var batchId: String
    public var bookId: String
    public var kind: RecordKind
    public var recordId: String
    public var baseVersion: Int
    public var deleted: Bool
    public var payloadJSON: Data?
    public var clientTime: String

    public init(changeId: String, batchId: String, bookId: String, kind: RecordKind, recordId: String, baseVersion: Int, deleted: Bool, payloadJSON: Data?, clientTime: String) {
        self.changeId = changeId
        self.batchId = batchId
        self.bookId = bookId
        self.kind = kind
        self.recordId = recordId
        self.baseVersion = baseVersion
        self.deleted = deleted
        self.payloadJSON = payloadJSON
        self.clientTime = clientTime
    }
}

public struct LocalRecordState: Sendable {
    public var bookId: String
    public var kind: RecordKind
    public var recordId: String
    public var serverVersion: Int
    public var dirty: Bool
    public var deleted: Bool
    public var payloadJSON: Data?

    public init(bookId: String, kind: RecordKind, recordId: String, serverVersion: Int, dirty: Bool, deleted: Bool, payloadJSON: Data?) {
        self.bookId = bookId
        self.kind = kind
        self.recordId = recordId
        self.serverVersion = serverVersion
        self.dirty = dirty
        self.deleted = deleted
        self.payloadJSON = payloadJSON
    }
}

/// Durable sync state kept in Application Support, never in the vault.
public final class SyncStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("sync.sqlite").path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
            throw SyncAPIError(status: 0, code: "store", message: "could not open sync.sqlite")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=FULL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS records (
            book_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            server_version INTEGER NOT NULL DEFAULT 0,
            dirty INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            payload TEXT,
            PRIMARY KEY (book_id, kind, id)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS outbox (
            change_id TEXT PRIMARY KEY,
            batch_id TEXT NOT NULL,
            book_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            base_version INTEGER NOT NULL,
            deleted INTEGER NOT NULL,
            payload TEXT,
            client_time TEXT NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS books (
            sha256 TEXT PRIMARY KEY,
            book_id TEXT,
            format TEXT,
            title TEXT,
            filename TEXT,
            doc_id TEXT,
            size INTEGER,
            waiting_for_space INTEGER NOT NULL DEFAULT 0
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS conflicts (
            conflict_id TEXT PRIMARY KEY,
            book_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            record_id TEXT NOT NULL,
            base_version INTEGER NOT NULL,
            json TEXT NOT NULL
        );
        """)
    }

    deinit {
        lock.lock()
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        lock.unlock()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func meta(_ key: String) -> String? {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1;", -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: pointer)

        }
    }

    public func setMeta(_ key: String, _ value: String?) {
        withLock {

            if let value {
                try? exec("INSERT INTO meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", binds: [valueParam(key), valueParam(value)])
            } else {
                try? exec("DELETE FROM meta WHERE key = ?1;", binds: [valueParam(key)])
            }

        }
    }

    public var cursor: Int {
        get { withLock { Int(meta("cursor") ?? "0") ?? 0 } }
        set { withLock { setMeta("cursor", String(newValue)) } }
    }

    public var serverId: String? {
        get { withLock { meta("serverId") } }
        set { withLock { setMeta("serverId", newValue) } }
    }

    public var deviceId: String {
        withLock {
            if let existing = meta("deviceId"), !existing.isEmpty { return existing }
            let created = UUID().uuidString.lowercased()
            setMeta("deviceId", created)
            return created
        }
    }

    public var deviceName: String? {
        get { withLock { meta("deviceName") } }
        set { withLock { setMeta("deviceName", newValue) } }
    }

    public var storageFull: Bool {
        get { withLock { meta("storageFull") == "1" } }
        set { withLock { setMeta("storageFull", newValue ? "1" : "0") } }
    }

    public func record(bookId: String, kind: RecordKind, recordId: String) -> LocalRecordState? {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT server_version, dirty, deleted, payload FROM records WHERE book_id = ?1 AND kind = ?2 AND id = ?3;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, kind.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, recordId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let payload: Data?
            if let pointer = sqlite3_column_text(statement, 3) {
                payload = String(cString: pointer).data(using: .utf8)
            } else {
                payload = nil
            }
            return LocalRecordState(
                bookId: bookId,
                kind: kind,
                recordId: recordId,
                serverVersion: Int(sqlite3_column_int64(statement, 0)),
                dirty: sqlite3_column_int(statement, 1) != 0,
                deleted: sqlite3_column_int(statement, 2) != 0,
                payloadJSON: payload
            )

        }
    }

    public func upsertRecord(_ state: LocalRecordState) {
        withLock {

            let payload = state.payloadJSON.flatMap { String(data: $0, encoding: .utf8) }
            try? exec(
                """
                INSERT INTO records(book_id, kind, id, server_version, dirty, deleted, payload)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                ON CONFLICT(book_id, kind, id) DO UPDATE SET
                    server_version = excluded.server_version,
                    dirty = excluded.dirty,
                    deleted = excluded.deleted,
                    payload = excluded.payload;
                """,
                binds: [
                    valueParam(state.bookId),
                    valueParam(state.kind.rawValue),
                    valueParam(state.recordId),
                    .int(state.serverVersion),
                    .int(state.dirty ? 1 : 0),
                    .int(state.deleted ? 1 : 0),
                    payload.map { .text($0) } ?? .null,
                ]
            )

        }
    }

    public func markClean(bookId: String, kind: RecordKind, recordId: String, version: Int) {
        withLock {

            if var state = record(bookId: bookId, kind: kind, recordId: recordId) {
                state.serverVersion = version
                state.dirty = false
                upsertRecord(state)
            } else {
                upsertRecord(LocalRecordState(bookId: bookId, kind: kind, recordId: recordId, serverVersion: version, dirty: false, deleted: false, payloadJSON: nil))
            }

        }
    }

    public func enqueue(_ item: OutboxItem) {
        withLock {

            let payload = item.payloadJSON.flatMap { String(data: $0, encoding: .utf8) }
            try? exec(
                """
                INSERT OR REPLACE INTO outbox(change_id, batch_id, book_id, kind, id, base_version, deleted, payload, client_time)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
                """,
                binds: [
                    valueParam(item.changeId),
                    valueParam(item.batchId),
                    valueParam(item.bookId),
                    valueParam(item.kind.rawValue),
                    valueParam(item.recordId),
                    .int(item.baseVersion),
                    .int(item.deleted ? 1 : 0),
                    payload.map { .text($0) } ?? .null,
                    valueParam(item.clientTime),
                ]
            )

        }
    }

    public func outbox() -> [OutboxItem] {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT change_id, batch_id, book_id, kind, id, base_version, deleted, payload, client_time FROM outbox;", -1, &statement, nil) == SQLITE_OK else { return [] }
            var items: [OutboxItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ index: Int32) -> String {
                    guard let pointer = sqlite3_column_text(statement, index) else { return "" }
                    return String(cString: pointer)
                }
                let payload: Data?
                if let pointer = sqlite3_column_text(statement, 7) {
                    payload = String(cString: pointer).data(using: .utf8)
                } else {
                    payload = nil
                }
                guard let kind = RecordKind(rawValue: text(3)) else { continue }
                items.append(OutboxItem(
                    changeId: text(0),
                    batchId: text(1),
                    bookId: text(2),
                    kind: kind,
                    recordId: text(4),
                    baseVersion: Int(sqlite3_column_int64(statement, 5)),
                    deleted: sqlite3_column_int(statement, 6) != 0,
                    payloadJSON: payload,
                    clientTime: text(8)
                ))
            }
            return items

        }
    }

    public func removeOutbox(changeIds: [String]) {
        withLock {

            for id in changeIds {
                try? exec("DELETE FROM outbox WHERE change_id = ?1;", binds: [valueParam(id)])
            }

        }
    }

    public func mergeOutbox(for key: (bookId: String, kind: RecordKind, recordId: String), into item: OutboxItem) {
        withLock {

            try? exec("DELETE FROM outbox WHERE book_id = ?1 AND kind = ?2 AND id = ?3;", binds: [valueParam(key.bookId), valueParam(key.kind.rawValue), valueParam(key.recordId)])
            enqueue(item)

        }
    }

    public func rememberBook(sha256: String, bookId: String?, format: String, title: String, filename: String, docId: String?, size: Int, waitingForSpace: Bool) {
        withLock {

            try? exec(
                """
                INSERT INTO books(sha256, book_id, format, title, filename, doc_id, size, waiting_for_space)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT(sha256) DO UPDATE SET
                    book_id = excluded.book_id,
                    format = excluded.format,
                    title = excluded.title,
                    filename = excluded.filename,
                    doc_id = excluded.doc_id,
                    size = excluded.size,
                    waiting_for_space = excluded.waiting_for_space;
                """,
                binds: [
                    valueParam(sha256),
                    bookId.map { .text($0) } ?? .null,
                    valueParam(format),
                    valueParam(title),
                    valueParam(filename),
                    docId.map { .text($0) } ?? .null,
                    .int(size),
                    .int(waitingForSpace ? 1 : 0),
                ]
            )

        }
    }

    public func bookId(forSha256 sha256: String) -> String? {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT book_id FROM books WHERE sha256 = ?1;", -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, sha256, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { return nil }
            let value = String(cString: pointer)
            return value.isEmpty ? nil : value

        }
    }

    public func waitingBookCount() -> Int {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM books WHERE waiting_for_space = 1;", -1, &statement, nil) == SQLITE_OK else { return 0 }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))

        }
    }

    public func waitingBooks() -> [(sha256: String, title: String, filename: String, size: Int)] {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT sha256, title, filename, size FROM books WHERE waiting_for_space = 1;", -1, &statement, nil) == SQLITE_OK else { return [] }
            var rows: [(String, String, String, Int)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let pointer = sqlite3_column_text(statement, i) else { return "" }
                    return String(cString: pointer)
                }
                rows.append((text(0), text(1), text(2), Int(sqlite3_column_int64(statement, 3))))
            }
            return rows

        }
    }

    public func clearWaiting(sha256: String) {
        withLock {

            try? exec("UPDATE books SET waiting_for_space = 0 WHERE sha256 = ?1;", binds: [valueParam(sha256)])
            if waitingBookCount() == 0 { storageFull = false }

        }
    }

    public func saveConflict(_ conflict: OpenConflict, json: Data) {
        withLock {

            let text = String(data: json, encoding: .utf8) ?? "{}"
            try? exec(
                """
                INSERT INTO conflicts(conflict_id, book_id, kind, record_id, base_version, json)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(conflict_id) DO UPDATE SET json = excluded.json, base_version = excluded.base_version;
                """,
                binds: [valueParam(conflict.conflictId), valueParam(conflict.bookId), valueParam(conflict.kind.rawValue), valueParam(conflict.recordId), .int(conflict.baseVersion), valueParam(text)]
            )

        }
    }

    public func removeConflict(_ conflictId: String) {
        withLock {

            try? exec("DELETE FROM conflicts WHERE conflict_id = ?1;", binds: [valueParam(conflictId)])

        }
    }

    public func conflicts() -> [OpenConflict] {
        withLock {

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT json FROM conflicts;", -1, &statement, nil) == SQLITE_OK else { return [] }
            var items: [OpenConflict] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pointer = sqlite3_column_text(statement, 0),
                      let data = String(cString: pointer).data(using: .utf8),
                      let object = try? JSONSupport.object(from: data),
                      let conflict = OpenConflict.parse(object) else { continue }
                items.append(conflict)
            }
            return items

        }
    }

    public func resetForNewServer() {
        withLock {

            try? exec("DELETE FROM records;")
            try? exec("DELETE FROM outbox;")
            try? exec("DELETE FROM conflicts;")
            cursor = 0

        }
    }

    // MARK: - SQLite helpers

    private enum Bind {
        case text(String)
        case int(Int)
        case null
    }

    private func valueParam(_ text: String) -> Bind { .text(text) }

    private func exec(_ sql: String, binds: [Bind] = []) throws {
        try withLock {

            if binds.isEmpty {
                var error: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                    let message = error.map { String(cString: $0) } ?? "sqlite error"
                    sqlite3_free(error)
                    throw SyncAPIError(status: 0, code: "store", message: message)
                }
                return
            }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "prepare failed"
                throw SyncAPIError(status: 0, code: "store", message: message)
            }
            for (index, bind) in binds.enumerated() {
                let i = Int32(index + 1)
                switch bind {
                case .text(let text): sqlite3_bind_text(statement, i, text, -1, SQLITE_TRANSIENT)
                case .int(let value): sqlite3_bind_int64(statement, i, sqlite3_int64(value))
                case .null: sqlite3_bind_null(statement, i)
                }
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "exec failed"
                throw SyncAPIError(status: 0, code: "store", message: message)
            }

        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
