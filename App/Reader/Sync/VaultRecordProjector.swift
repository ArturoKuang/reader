import Foundation
import ReaderCore
import ReaderSync

/// Projects accepted sync records into an open Reader session (and thereby into
/// the Mac vault via the existing VaultCoordinator). Never writes conflict-copy files.
final class VaultRecordProjector: SyncVaultWriting {
    static let shared = VaultRecordProjector()

    func applyAcceptedRecords(_ records: [RecordEnvelope], vaultRoot: URL?) throws {
        // Conflict copies are never written, including when a throwaway vault is provided.
        guard let vaultRoot else { return }
        _ = records
        _ = vaultRoot
    }

    func apply(records: [RecordEnvelope], to session: ReaderSession) {
        guard !records.isEmpty else { return }
        var highlights = session.package.highlights.highlights
        var notes = session.package.notes.notes
        var words = session.package.words.words
        var lookupsByWord: [String: [LookupEntry]] = [:]
        for word in words {
            lookupsByWord[word.id] = word.lookups
        }
        for record in records where record.kind != .position && record.kind != .book {
            switch record.kind {
            case .highlight:
                if record.deleted {
                    highlights.removeAll { $0.id == record.recordId }
                } else if let payload = record.payload {
                    let entry = RecordAdapter.highlight(from: payload, id: record.recordId)
                    if let index = highlights.firstIndex(where: { $0.id == entry.id }) {
                        highlights[index] = entry
                    } else {
                        highlights.append(entry)
                    }
                }
            case .note:
                if record.deleted {
                    notes.removeAll { $0.id == record.recordId }
                } else if let payload = record.payload {
                    let entry = RecordAdapter.note(from: payload, id: record.recordId)
                    if let index = notes.firstIndex(where: { $0.id == entry.id }) {
                        notes[index] = entry
                    } else {
                        notes.append(entry)
                    }
                }
            case .word:
                if record.deleted {
                    words.removeAll { $0.id == record.recordId }
                    lookupsByWord[record.recordId] = nil
                } else if let payload = record.payload {
                    let existing = lookupsByWord[record.recordId] ?? []
                    let entry = RecordAdapter.word(from: payload, id: record.recordId, lookups: existing)
                    if let index = words.firstIndex(where: { $0.id == entry.id }) {
                        words[index] = entry
                    } else {
                        words.append(entry)
                    }
                }
            case .lookup:
                if let payload = record.payload {
                    let entry = RecordAdapter.lookup(from: payload, id: record.recordId)
                    let wordId = payload["wordId"] as? String ?? ""
                    var list = lookupsByWord[wordId] ?? []
                    if record.deleted {
                        list.removeAll { $0.id == entry.id }
                    } else if let index = list.firstIndex(where: { $0.id == entry.id }) {
                        list[index] = entry
                    } else {
                        list.append(entry)
                    }
                    list.sort { ($0.date, $0.id) < ($1.date, $1.id) }
                    lookupsByWord[wordId] = list
                    if let index = words.firstIndex(where: { $0.id == wordId }) {
                        words[index].lookups = list
                    }
                }
            default:
                break
            }
        }
        session.package.highlights.highlights = highlights
        session.package.notes.notes = notes
        session.package.words.words = words
        session.publishAnnotationsChanged()
        session.objectWillChange.send()
        if session.usesVault {
            session.onVaultFlush?()
        } else {
            session.onSaveVaultState?()
        }
    }
}
