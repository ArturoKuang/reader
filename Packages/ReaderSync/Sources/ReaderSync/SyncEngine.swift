import Foundation
import ReaderCore

public struct BookSyncSnapshot: Sendable {
    public var fileURL: URL
    public var fileData: Data
    public var format: String
    public var title: String
    public var docId: String?
    public var highlights: [HighlightEntry]
    public var notes: [NoteEntry]
    public var words: [WordEntry]
    public var isPDF: Bool
    public var page: Int?
    public var pdfPoint: (x: Double, y: Double)?
    public var cfi: String?

    public init(
        fileURL: URL,
        fileData: Data,
        format: String,
        title: String,
        docId: String?,
        highlights: [HighlightEntry],
        notes: [NoteEntry],
        words: [WordEntry],
        isPDF: Bool,
        page: Int?,
        pdfPoint: (x: Double, y: Double)?,
        cfi: String?
    ) {
        self.fileURL = fileURL
        self.fileData = fileData
        self.format = format
        self.title = title
        self.docId = docId
        self.highlights = highlights
        self.notes = notes
        self.words = words
        self.isPDF = isPDF
        self.page = page
        self.pdfPoint = pdfPoint
        self.cfi = cfi
    }

    public var sha256: String { SHA256.hex(fileData) }
    public var fingerprint: String { SHA256.fingerprint(fileData) }
}

public protocol SyncVaultWriting: AnyObject {
    /// Project accepted records into the Mac vault. Must never write conflict-copy files.
    func applyAcceptedRecords(_ records: [RecordEnvelope], vaultRoot: URL?) throws
}

public final class SyncEngine: @unchecked Sendable {
    public let store: SyncStore
    public let credentials: CredentialStoring
    public let http: SyncHTTPClient
    public let api: TailDriveAPI
    public weak var vaultWriter: SyncVaultWriting?
    public var vaultRoot: URL?

    public private(set) var devices: [PairedDevice] = []
    public private(set) var lastQR: IssuedPairingToken?
    public private(set) var unreachable = false
    public private(set) var syncing = false
    public private(set) var lastError: String?
    public private(set) var appliedRecords: [RecordEnvelope] = []
    private var pendingProjectionRecords: [RecordEnvelope] = []

    /// Returns newly pulled or conflict-resolved records waiting to be projected into open sessions.
    public func takePendingProjectionRecords(forBookIds bookIds: Set<String>) -> [RecordEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        var matched: [RecordEnvelope] = []
        var remaining: [RecordEnvelope] = []
        for record in pendingProjectionRecords {
            if bookIds.contains(record.bookId) {
                matched.append(record)
            } else {
                remaining.append(record)
            }
        }
        pendingProjectionRecords = remaining
        return matched
    }

    private let lock = NSLock()
    private let pairingGate = PairingGate()

    public init(
        directory: URL,
        configuration: SyncClientConfiguration,
        credentials: CredentialStoring,
        transport: SyncTransporting = URLSessionSyncTransport()
    ) throws {
        self.store = try SyncStore(directory: directory)
        self.credentials = credentials
        let http = SyncHTTPClient(configuration: configuration, credential: credentials.load(account: SyncKeychainAccount.credential), transport: transport)
        self.http = http
        self.api = TailDriveAPI(http: http)
        if let name = configuration.deviceName as String? {
            store.deviceName = name
        }
    }

    public var isPaired: Bool {
        credentials.load(account: SyncKeychainAccount.credential) != nil
    }

    public var macDeviceId: String { store.deviceId }

    public func status() -> SyncStatusSnapshot {
        let conflicts = store.conflicts()
        let waiting = store.waitingBookCount()
        let state = SyncChipState.resolve(
            unreachable: unreachable,
            storageFull: store.storageFull || waiting > 0,
            conflictCount: conflicts.count,
            offline: unreachable == false && http.credential == nil && !isPaired ? false : (unreachable && hasLocalChanges()),
            syncing: syncing
        )
        // If we have local changes and we already flagged unreachable, prefer error (can't reach)
        // which is already highest priority.
        return SyncStatusSnapshot(
            state: state,
            conflictCount: conflicts.count,
            waitingBookCount: waiting,
            lastError: lastError,
            hostCaption: http.configuration.hostCaption,
            isPaired: isPaired
        )
    }

    public func conflicts() -> [OpenConflict] { store.conflicts() }

    public func waitingBooks() -> [(sha256: String, title: String, filename: String, size: Int)] {
        store.waitingBooks()
    }

    // MARK: - Pairing

    @discardableResult
    public func ensureMacPaired() async throws -> RedeemResponse {
        try await pairingGate.run {
            try await self.performEnsureMacPaired()
        }
    }

    private func performEnsureMacPaired() async throws -> RedeemResponse {
        if let credential = credentials.load(account: SyncKeychainAccount.credential) {
            http.credential = credential
            let deviceId = credentials.load(account: SyncKeychainAccount.deviceId) ?? store.deviceId
            store.setMeta("deviceId", deviceId)
            return RedeemResponse(deviceId: deviceId, credential: credential, serverId: credentials.load(account: SyncKeychainAccount.serverId) ?? store.serverId ?? "", kind: "mac")
        }
        let issued = try await api.issuePairingToken(kind: "mac")
        let redeemed = try await api.redeem(
            token: issued.token,
            deviceId: store.deviceId,
            name: store.deviceName ?? http.configuration.deviceName,
            platform: "macos",
            appVersion: http.configuration.appVersion
        )
        try saveCredential(redeemed)
        return redeemed
    }

    public func issuePhoneQR() async throws -> IssuedPairingToken {
        try await ensureMacPaired()
        let issued = try await api.issuePairingToken(kind: "phone")
        lastQR = issued
        return issued
    }

    public func refreshDevices() async throws -> [PairedDevice] {
        try await ensureMacPaired()
        let list = try await api.devices()
        devices = list.filter { !$0.revoked }
        unreachable = false
        lastError = nil
        return devices
    }

    public func revokeDevice(id: String) async throws {
        try await ensureMacPaired()
        try await api.revokeDevice(id)
        devices = devices.filter { $0.deviceId != id }
    }

    // MARK: - Sync loop

    public func sync(snapshot: BookSyncSnapshot? = nil) async throws {
        syncing = true
        defer { syncing = false }
        try await ensureMacPaired()
        if let snapshot {
            try await ingest(snapshot)
        }
        try await pushOutbox()
        try await pullAll()
        if store.storageFull || store.waitingBookCount() > 0 {
            try await retryWaitingUploads()
        }
        _ = try? await refreshDevices()
    }

    public func ingest(_ snapshot: BookSyncSnapshot) async throws {
        let bookId = try await registerAndMaybeUpload(snapshot)
        enqueueLocalRecords(snapshot, bookId: bookId)
    }

    public func resolve(conflict: OpenConflict, choice: ConflictChoice) async throws {
        let macIds = Set(devices.filter(\.isMac).map(\.deviceId) + [macDeviceId])
        let prepared = try ConflictResolution.prepare(conflict: conflict, choice: choice, macDeviceIds: macIds)
        _ = try await api.resolve(conflictId: conflict.conflictId, request: prepared.request)
        store.removeConflict(conflict.conflictId)
        // Apply the winning record through the normal vault writer, never as a conflict file.
        let envelope = RecordEnvelope(
            bookId: conflict.bookId,
            kind: conflict.kind,
            recordId: conflict.recordId,
            version: conflict.baseVersion + 1,
            baseVersion: conflict.baseVersion,
            deleted: prepared.request.deleted,
            deviceId: macDeviceId,
            changeId: prepared.request.changeId,
            clientTime: isoNow(),
            seq: nil,
            payload: prepared.request.payload,
            conflict: nil
        )
        store.upsertRecord(LocalRecordState(
            bookId: envelope.bookId,
            kind: envelope.kind,
            recordId: envelope.recordId,
            serverVersion: envelope.version,
            dirty: false,
            deleted: envelope.deleted,
            payloadJSON: envelope.payload.flatMap { try? JSONSupport.data($0) }
        ))
        recordApplied([envelope])
        try vaultWriter?.applyAcceptedRecords([envelope], vaultRoot: vaultRoot)
    }

    public func retryWaitingUploads() async throws {
        for book in store.waitingBooks() {
            // Re-HEAD and upload if the file is still around is the caller's job; this
            // just clears the flag when the server already has the blob.
            do {
                let head = try await api.headBlob(sha256: book.sha256)
                if head.complete {
                    store.clearWaiting(sha256: book.sha256)
                }
            } catch let error as SyncAPIError where error.isDiskFull {
                store.storageFull = true
                return
            } catch let error as SyncAPIError where error.isNetwork {
                unreachable = true
                lastError = error.message
                return
            }
        }
    }

    // MARK: - Internals

    private func saveCredential(_ redeemed: RedeemResponse) throws {
        try credentials.save(account: SyncKeychainAccount.credential, secret: redeemed.credential)
        try credentials.save(account: SyncKeychainAccount.deviceId, secret: redeemed.deviceId)
        try credentials.save(account: SyncKeychainAccount.serverId, secret: redeemed.serverId)
        store.setMeta("deviceId", redeemed.deviceId)
        store.serverId = redeemed.serverId
        http.credential = redeemed.credential
    }

    private func hasLocalChanges() -> Bool { !store.outbox().isEmpty }

    private func registerAndMaybeUpload(_ snapshot: BookSyncSnapshot) async throws -> String {
        if let existing = store.bookId(forSha256: snapshot.sha256) {
            // Still try to finish a waiting upload.
            if store.waitingBooks().contains(where: { $0.sha256 == snapshot.sha256 }) {
                try await uploadBook(snapshot)
            }
            return existing
        }
        let registered = try await api.registerBook(
            sha256: snapshot.sha256,
            size: snapshot.fileData.count,
            format: snapshot.format,
            title: snapshot.title,
            filename: snapshot.fileURL.lastPathComponent,
            docId: snapshot.docId
        )
        store.rememberBook(
            sha256: snapshot.sha256,
            bookId: registered.bookId,
            format: snapshot.format,
            title: snapshot.title,
            filename: snapshot.fileURL.lastPathComponent,
            docId: snapshot.docId,
            size: snapshot.fileData.count,
            waitingForSpace: false
        )
        try await uploadBook(snapshot)
        return registered.bookId
    }

    private func uploadBook(_ snapshot: BookSyncSnapshot) async throws {
        do {
            let head = try await api.headBlob(sha256: snapshot.sha256)
            if head.complete {
                store.clearWaiting(sha256: snapshot.sha256)
                return
            }
            try await api.uploadBlob(sha256: snapshot.sha256, data: snapshot.fileData, existingOffset: head.offset)
            store.clearWaiting(sha256: snapshot.sha256)
        } catch let error as SyncAPIError where error.isDiskFull {
            store.storageFull = true
            store.rememberBook(
                sha256: snapshot.sha256,
                bookId: store.bookId(forSha256: snapshot.sha256),
                format: snapshot.format,
                title: snapshot.title,
                filename: snapshot.fileURL.lastPathComponent,
                docId: snapshot.docId,
                size: snapshot.fileData.count,
                waitingForSpace: true
            )
            // Record pushes keep going; book upload waits.
        }
    }

    private struct RecordKey: Hashable {
        let bookId: String
        let kind: RecordKind
        let recordId: String
    }

    private func recordApplied(_ records: [RecordEnvelope]) {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for envelope in records {
            if let existing = appliedRecords.firstIndex(where: {
                $0.bookId == envelope.bookId && $0.kind == envelope.kind && $0.recordId == envelope.recordId
            }) {
                appliedRecords[existing] = envelope
            } else {
                appliedRecords.append(envelope)
            }
            if let pending = pendingProjectionRecords.firstIndex(where: {
                $0.bookId == envelope.bookId && $0.kind == envelope.kind && $0.recordId == envelope.recordId
            }) {
                pendingProjectionRecords[pending] = envelope
            } else {
                pendingProjectionRecords.append(envelope)
            }
        }
    }

    private func dropLocallyDeletedFromApplied(bookId: String, kind: RecordKind, recordId: String) {
        lock.lock()
        defer { lock.unlock() }
        appliedRecords.removeAll { $0.bookId == bookId && $0.kind == kind && $0.recordId == recordId }
        pendingProjectionRecords.removeAll { $0.bookId == bookId && $0.kind == kind && $0.recordId == recordId }
    }

    private func enqueueLocalRecords(_ snapshot: BookSyncSnapshot, bookId: String) {
        var liveKeys = Set<RecordKey>()

        func enqueue(kind: RecordKind, recordId: String, payload: [String: Any]?, deleted: Bool = false) {
            if !deleted {
                liveKeys.insert(RecordKey(bookId: bookId, kind: kind, recordId: recordId))
            }
            let current = store.record(bookId: bookId, kind: kind, recordId: recordId)
            let payloadData = payload.flatMap { try? JSONSupport.data($0) }
            if let current, !current.dirty, current.deleted == deleted, (deleted || current.payloadJSON == payloadData) {
                return
            }
            let base = current?.serverVersion ?? 0
            let item = OutboxItem(
                changeId: newChangeId(),
                batchId: newBatchId(),
                bookId: bookId,
                kind: kind,
                recordId: recordId,
                baseVersion: base,
                deleted: deleted,
                payloadJSON: deleted ? nil : payloadData,
                clientTime: isoNow()
            )
            store.mergeOutbox(for: (bookId, kind, recordId), into: item)
            store.upsertRecord(LocalRecordState(bookId: bookId, kind: kind, recordId: recordId, serverVersion: base, dirty: true, deleted: deleted, payloadJSON: deleted ? nil : payloadData))
            if deleted {
                dropLocallyDeletedFromApplied(bookId: bookId, kind: kind, recordId: recordId)
            }
        }

        let notesById = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
        for highlight in snapshot.highlights {
            enqueue(kind: .highlight, recordId: highlight.id, payload: RecordAdapter.highlightPayload(highlight))
            if let noteId = highlight.noteID, let note = notesById[noteId] {
                enqueue(kind: .note, recordId: note.id, payload: RecordAdapter.notePayload(note, highlightId: highlight.id))
            }
        }
        for note in snapshot.notes where !snapshot.highlights.contains(where: { $0.noteID == note.id }) {
            enqueue(kind: .note, recordId: note.id, payload: RecordAdapter.notePayload(note, highlightId: nil))
        }
        for word in snapshot.words {
            let id = word.id.hasPrefix("w_") ? word.id : RecordAdapter.wordId(for: word.word)
            enqueue(kind: .word, recordId: id, payload: RecordAdapter.wordPayload(word))
            for lookup in word.lookups {
                enqueue(kind: .lookup, recordId: lookup.id, payload: RecordAdapter.lookupPayload(lookup, wordId: id))
            }
        }

        // Propagate local deletions as tombstones so deleted notes, highlights, and words
        // stay deleted instead of being resurrected by sync pulls.
        let deletableKinds: Set<RecordKind> = [.highlight, .note, .word, .lookup]
        for stored in store.records(bookId: bookId) where deletableKinds.contains(stored.kind) && !stored.deleted {
            let key = RecordKey(bookId: bookId, kind: stored.kind, recordId: stored.recordId)
            if !liveKeys.contains(key) {
                enqueue(kind: stored.kind, recordId: stored.recordId, payload: nil, deleted: true)
            }
        }

        let positionId = RecordAdapter.positionId(bookId: bookId, deviceId: store.deviceId)
        let payload = RecordAdapter.positionPayload(
            bookId: bookId,
            deviceId: store.deviceId,
            isPDF: snapshot.isPDF,
            page: snapshot.page,
            point: snapshot.pdfPoint,
            cfi: snapshot.cfi
        )
        enqueue(kind: .position, recordId: positionId, payload: payload)
    }

    private func pushOutbox() async throws {
        let items = store.outbox()
        guard !items.isEmpty else { return }
        // One change per key already ensured by mergeOutbox. Group into batches of <= 500.
        let batches = stride(from: 0, to: items.count, by: 500).map { Array(items[$0..<min($0 + 500, items.count)]) }
        for batchItems in batches {
            let batchId = batchItems.first?.batchId ?? newBatchId()
            let changes: [PushChange] = batchItems.map { item in
                let payload = item.payloadJSON.flatMap { try? JSONSupport.object(from: $0) }
                return PushChange(
                    changeId: item.changeId,
                    bookId: item.bookId,
                    kind: item.kind,
                    recordId: item.recordId,
                    baseVersion: item.baseVersion,
                    deleted: item.deleted,
                    clientTime: item.clientTime,
                    payload: payload
                )
            }
            do {
                let response = try await api.push(batchId: batchId, changes: changes)
                unreachable = false
                for result in response.results {
                    if result.isApplied, let version = result.version {
                        if let item = batchItems.first(where: { $0.changeId == result.changeId }) {
                            store.markClean(bookId: item.bookId, kind: item.kind, recordId: item.recordId, version: version)
                        }
                        store.removeOutbox(changeIds: [result.changeId])
                    } else if result.isConflict, let item = batchItems.first(where: { $0.changeId == result.changeId }) {
                        store.removeOutbox(changeIds: [result.changeId])
                        store.upsertRecord(LocalRecordState(bookId: item.bookId, kind: item.kind, recordId: item.recordId, serverVersion: item.baseVersion, dirty: false, deleted: item.deleted, payloadJSON: item.payloadJSON))
                    } else if result.status == "rejected" {
                        // Leave in the outbox only for transient unknown_book; drop bad_base after a pull.
                        if result.errorCode == "unknown_book" { continue }
                        store.removeOutbox(changeIds: [result.changeId])
                    }
                }
            } catch let error as SyncAPIError where error.isNetwork {
                unreachable = true
                lastError = error.message
                throw error
            }
        }
    }

    private func pullAll() async throws {
        var health: HealthResponse
        do {
            health = try await api.health()
        } catch let error as SyncAPIError {
            if error.isNetwork {
                unreachable = true
                lastError = error.message
            }
            throw error
        }
        if let previous = store.serverId, !previous.isEmpty, previous != health.serverId {
            store.resetForNewServer()
            store.serverId = health.serverId
        } else if store.serverId == nil {
            store.serverId = health.serverId
        }
        var since = store.cursor
        var accepted: [RecordEnvelope] = []
        while true {
            let page = try await api.pull(since: since)
            if page.serverId != health.serverId && !page.serverId.isEmpty {
                store.resetForNewServer()
                since = 0
                store.serverId = page.serverId
                continue
            }
            for change in page.changes {
                if let conflict = change.conflict {
                    if let data = try? JSONSupport.data(conflictJSON(conflict)) {
                        store.saveConflict(conflict, json: data)
                    }
                }
                if let existing = store.record(bookId: change.bookId, kind: change.kind, recordId: change.recordId), existing.dirty {
                    // Never overwrite a dirty local record; push and let the server decide.
                    continue
                }
                store.upsertRecord(LocalRecordState(
                    bookId: change.bookId,
                    kind: change.kind,
                    recordId: change.recordId,
                    serverVersion: change.version,
                    dirty: false,
                    deleted: change.deleted,
                    payloadJSON: change.payload.flatMap { try? JSONSupport.data($0) }
                ))
                accepted.append(change)
            }
            store.cursor = page.cursor
            since = page.cursor
            if !page.hasMore { break }
        }
        unreachable = false
        lastError = nil
        recordApplied(accepted)
        if !accepted.isEmpty {
            try vaultWriter?.applyAcceptedRecords(accepted, vaultRoot: vaultRoot)
        }
        if let listed = try? await api.conflicts() {
            for conflict in listed {
                if let data = try? JSONSupport.data(conflictJSON(conflict)) {
                    store.saveConflict(conflict, json: data)
                }
            }
        }
    }

    private func conflictJSON(_ conflict: OpenConflict) -> [String: Any] {
        [
            "conflictId": conflict.conflictId,
            "bookId": conflict.bookId,
            "kind": conflict.kind.rawValue,
            "id": conflict.recordId,
            "baseVersion": conflict.baseVersion,
            "sides": conflict.sides.map { side -> [String: Any] in
                var object: [String: Any] = [
                    "changeId": side.changeId,
                    "deviceId": side.deviceId,
                    "deleted": side.deleted,
                ]
                if let version = side.version { object["version"] = version }
                if let time = side.clientTime { object["clientTime"] = time }
                if let payload = side.payload { object["payload"] = payload }
                return object
            },
        ]
    }
}

/// Serializes Mac pairing so concurrent refreshDevices() / issuePhoneQR() / sync()
/// calls share one in-flight pair instead of racing on meta writes or double-redeeming.
private actor PairingGate {
    private var inFlight: Task<RedeemResponse, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> RedeemResponse) async throws -> RedeemResponse {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
