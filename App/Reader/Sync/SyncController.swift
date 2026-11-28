import AppKit
import Combine
import Foundation
import ReaderCore
import ReaderSync
import SwiftUI

@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController()

    @Published private(set) var status = SyncStatusSnapshot(state: .offline, hostCaption: SyncClientConfiguration.productionBaseURL.host ?? "")
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var issuedQR: IssuedPairingToken?
    @Published private(set) var qrImage: NSImage?
    @Published var confirmRevokeId: String?
    @Published var showingConflictReview = false
    @Published var lastMessage: String = ""

    let engine: SyncEngine?
    private var timer: Timer?
    private var openSessions: [ObjectIdentifier: WeakSession] = [:]
    private var pendingApply = false

    private struct WeakSession {
        weak var session: ReaderSession?
    }

    private init() {
        let support = URL(fileURLWithPath: AppPaths.support).appendingPathComponent("Sync", isDirectory: true)
        let defaults = UserDefaults.standard
        let urlString = defaults.string(forKey: "reader.sync.baseURL") ?? SyncClientConfiguration.productionBaseURL.absoluteString
        let baseURL = URL(string: urlString) ?? SyncClientConfiguration.productionBaseURL
        var loopback = defaults.string(forKey: "reader.sync.loopbackLogin")
        if loopback == nil, let host = baseURL.host, host == "127.0.0.1" || host == "localhost" {
            loopback = "arturo@local"
        }
        let configuration = SyncClientConfiguration(
            baseURL: baseURL,
            loopbackLogin: loopback,
            deviceName: Host.current().localizedName ?? "Mac",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
        do {
            engine = try SyncEngine(
                directory: support,
                configuration: configuration,
                credentials: SecretStore.shared
            )
            engine?.vaultWriter = VaultRecordProjector.shared
        } catch {
            engine = nil
            lastMessage = error.localizedDescription
        }
        refreshStatus()
    }

    var macDeviceId: String { engine?.macDeviceId ?? "" }

    func start() {
        refreshStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }
        Task { await syncNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func register(_ session: ReaderSession) {
        openSessions[ObjectIdentifier(session)] = WeakSession(session: session)
        let existing = session.onSyncNeeded
        session.onSyncNeeded = { [weak self, weak session] in
            existing?()
            guard let self, let session else { return }
            Task { @MainActor in
                await self.sessionDidChange(session)
            }
        }
        Task { await applyPulledRecords(to: session) }
    }

    func unregister(_ session: ReaderSession) {
        openSessions[ObjectIdentifier(session)] = nil
    }

    func refreshStatus() {
        guard let engine else { return }
        status = engine.status()
        devices = engine.devices
        if showingConflictReview == false, status.state == .conflict, status.conflictCount > 0 {
            // chip click opens the sheet; don't auto-present
        }
    }

    func syncNow() async {
        guard let engine else { return }
        do {
            // Ingest every open book, then push/pull.
            for session in liveSessions() {
                if let snapshot = snapshot(from: session) {
                    try await engine.ingest(snapshot)
                }
            }
            try await engine.sync()
            lastMessage = ""
            for session in liveSessions() {
                await applyPulledRecords(to: session)
            }
        } catch let error as SyncAPIError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        if let token = issuedQR, token.expiresAt < Date() {
            issuedQR = nil
            qrImage = nil
        }
        refreshStatus()
    }

    func checkAgain() async {
        await syncNow()
    }

    func retry() async {
        await syncNow()
    }

    func showPhoneQR() async {
        guard let engine else { return }
        do {
            let issued = try await engine.issuePhoneQR()
            issuedQR = issued
            qrImage = QRCodeImage.make(issued.qr)
            devices = (try? await engine.refreshDevices()) ?? engine.devices
            lastMessage = ""
        } catch let error as SyncAPIError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        refreshStatus()
    }

    func dismissQR() {
        issuedQR = nil
        qrImage = nil
    }

    func refreshDevices() async {
        guard let engine else { return }
        do {
            devices = try await engine.refreshDevices()
            lastMessage = ""
        } catch let error as SyncAPIError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        refreshStatus()
    }

    func revoke(_ deviceId: String) async {
        guard let engine else { return }
        do {
            try await engine.revokeDevice(id: deviceId)
            confirmRevokeId = nil
            devices = engine.devices
            lastMessage = ""
        } catch let error as SyncAPIError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        refreshStatus()
    }

    func conflicts() -> [OpenConflict] { engine?.conflicts() ?? [] }

    func resolve(conflict: OpenConflict, choice: ConflictChoice) async {
        guard let engine else { return }
        do {
            try await engine.resolve(conflict: conflict, choice: choice)
            for session in liveSessions() {
                await applyPulledRecords(to: session)
            }
            lastMessage = ""
        } catch let error as SyncAPIError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        refreshStatus()
        if conflicts().isEmpty {
            showingConflictReview = false
        }
    }

    func handleChipClick() {
        if status.state == .conflict, status.conflictCount > 0 {
            showingConflictReview = true
        }
    }

    // MARK: - Session

    private func sessionDidChange(_ session: ReaderSession) async {
        guard let engine, let snapshot = snapshot(from: session) else { return }
        do {
            try await engine.ingest(snapshot)
            try await engine.sync()
            lastMessage = ""
        } catch let error as SyncAPIError {
            lastMessage = error.message
        } catch {
            lastMessage = error.localizedDescription
        }
        refreshStatus()
    }

    private func liveSessions() -> [ReaderSession] {
        openSessions.values.compactMap(\.session)
    }

    private func snapshot(from session: ReaderSession) -> BookSyncSnapshot? {
        let url = session.bookURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let format = session.isPDF ? "pdf" : "epub"
        let docId = session.isPDF ? session.package.notes.frontMatter.pdfID : session.package.notes.frontMatter.epubID
        let point: (x: Double, y: Double)? = nil
        return BookSyncSnapshot(
            fileURL: url,
            fileData: data,
            format: format,
            title: url.deletingPathExtension().lastPathComponent,
            docId: docId,
            highlights: session.package.highlights.highlights,
            notes: session.package.notes.notes,
            words: session.package.words.words,
            isPDF: session.isPDF,
            page: session.isPDF ? session.package.state.page : nil,
            pdfPoint: point,
            cfi: session.isPDF ? nil : EPUBPosition.chapterStart(cfi: session.currentEPUBCFI())
        )
    }

    private func applyPulledRecords(to session: ReaderSession) async {
        guard let engine else { return }
        let fingerprint = session.fingerprint
        let sha = fingerprint.replacingOccurrences(of: "sha256:", with: "")
        let bookId = engine.store.bookId(forSha256: sha) ?? fingerprint
        // Apply only newly pulled records for this book, skipping any record that is
        // currently locally deleted or dirty in SyncStore so deleted notes cannot resurrect.
        let bookIds: Set<String> = [bookId, fingerprint]
        let pending = engine.takePendingProjectionRecords(forBookIds: bookIds)
        guard !pending.isEmpty else { return }
        let safeRecords = pending.filter { record in
            if let local = engine.store.record(bookId: record.bookId, kind: record.kind, recordId: record.recordId) {
                if local.dirty { return false }
                if local.deleted && !record.deleted { return false }
            }
            return true
        }
        guard !safeRecords.isEmpty else { return }
        VaultRecordProjector.shared.apply(records: safeRecords, to: session)
    }

    func applyOpeningPosition(to session: ReaderSession) {
        // Positions apply only when a book is opened, never mid-session.
        guard let engine else { return }
        let fingerprint = session.fingerprint
        let sha = fingerprint.replacingOccurrences(of: "sha256:", with: "")
        let bookId = engine.store.bookId(forSha256: sha) ?? fingerprint
        // Highest seq wins; toast if the source is another device and the spot differs.
        // Stored as applied records of kind position.
        let positions = engine.appliedRecords.filter { $0.kind == .position && ($0.bookId == bookId || $0.bookId == fingerprint) && !$0.deleted }
        guard let newest = positions.max(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) else { return }
        guard newest.deviceId != engine.macDeviceId else { return }
        let locator = newest.payload?["locator"] as? [String: Any]
        if session.isPDF {
            let page = locator?["page"] as? Int ?? (locator?["page"] as? NSNumber)?.intValue
            if let page, abs(page - session.package.state.page) > 0 {
                let previous = session.package.state.page
                session.package.state.page = page
                session.page = page
                let device = engine.devices.first { $0.deviceId == newest.deviceId }
                let name = device?.kind == "phone" ? "your phone" : (device?.name ?? "another device")
                session.showToast("Opened where you left off on \(name) · Back to p. \(previous)")
            }
        } else if let cfi = locator?["cfi"] as? String {
            if !EPUBPosition.sameChapter(cfi, session.currentEPUBCFI()) {
                // Chapter-only landing in v1; the EPUB view uses state via the session if it already tracks CFI.
                let device = engine.devices.first { $0.deviceId == newest.deviceId }
                let name = device?.kind == "phone" ? "your phone" : (device?.name ?? "another device")
                session.showToast("Opened where you left off on \(name)")
            }
        }
    }
}

enum QRCodeImage {
    static func make(_ payload: String) -> NSImage? {
        let data = Data(payload.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: 160, height: 160))
        image.addRepresentation(rep)
        return image
    }
}
