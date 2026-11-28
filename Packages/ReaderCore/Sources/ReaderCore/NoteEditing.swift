import Foundation

/// The note side of one annotation at a moment in time. A blank note counts as no note.
public struct NoteState: Equatable, Sendable {
    public var highlightID: String?
    public var noteID: String?
    public var note: NoteEntry?
    public var linkedNoteID: String?
    public var index: Int

    /// `id` may be a highlight id or a note id.
    public static func capture(id: String, package: SidecarPackage) -> NoteState? {
        guard let item = AnnotationIndex.resolve(id: id, in: package) else { return nil }
        let entry = item.note
        let visible = entry.flatMap { AnnotationEdit.isBlankNote($0.body) ? nil : $0 }
        return NoteState(
            highlightID: item.highlight?.id,
            noteID: entry?.id ?? item.highlight?.noteID,
            note: visible,
            linkedNoteID: visible == nil ? nil : item.highlight?.noteID,
            index: entry.flatMap { note in package.notes.notes.firstIndex { $0.id == note.id } } ?? package.notes.notes.count
        )
    }

    /// Puts this state back and returns the state it replaced, so the change can be redone.
    /// Does nothing when the highlight it belonged to is gone.
    @discardableResult
    public func restore(into package: inout SidecarPackage) -> NoteState? {
        if let highlightID, !package.highlights.highlights.contains(where: { $0.id == highlightID }) { return nil }
        guard let key = highlightID ?? noteID else { return nil }
        // A removed standalone note no longer resolves; its previous state is "absent".
        let current = NoteState.capture(id: key, package: package)
            ?? NoteState(highlightID: highlightID, noteID: noteID, note: nil, linkedNoteID: nil, index: index)
        let replaced = Set([current.noteID, noteID].compactMap { $0 })
        package.notes.notes.removeAll { replaced.contains($0.id) }
        if let note {
            package.notes.notes.insert(note, at: min(max(index, 0), package.notes.notes.count))
        }
        if let highlightID, let position = package.highlights.highlights.firstIndex(where: { $0.id == highlightID }) {
            package.highlights.highlights[position].noteID = linkedNoteID
        }
        return current
    }
}

/// One editor's claim on one annotation. A revoked or finished token can no longer write.
public struct NoteEditToken: Hashable, Sendable {
    private let value = UUID()
    public init() {}
}

public struct NoteEditResult: Equatable, Sendable {
    /// The package differs from what it was before this call.
    public var changed: Bool
    /// The state to restore on undo. Nil when the edit left the note as it found it.
    public var undo: NoteState?
}

/// Typing that has not reached the package yet, and the state each open editor started from.
/// An annotation has at most one editor; beginning a second one finishes the first.
public struct NoteEditBuffer: Sendable {
    private struct Edit: Sendable {
        var key: String
        var baseline: NoteState
        /// Used when the first typing creates the note, so it keeps one id for the whole edit.
        var newNoteID: String
        /// The body this editor last saw in the package.
        var knownBody: String?
        var pending: String?
    }

    private var edits: [NoteEditToken: Edit] = [:]

    public init() {}

    public var hasPending: Bool { edits.values.contains { $0.pending != nil } }
    public var tokens: [NoteEditToken] { Array(edits.keys) }

    public func isActive(_ token: NoteEditToken) -> Bool { edits[token] != nil }

    public func annotationID(for token: NoteEditToken) -> String? { edits[token]?.key }

    public func token(editing id: String, in package: SidecarPackage) -> NoteEditToken? {
        let key = AnnotationIndex.resolve(id: id, in: package)?.id ?? id
        return edits.first { $0.value.key == key }?.key
    }

    public struct Begin: Sendable {
        public var token: NoteEditToken
        /// Editors that lost their claim, and what finishing them did.
        public var superseded: [(token: NoteEditToken, result: NoteEditResult)]
    }

    public mutating func begin(id: String, newNoteID: String, package: inout SidecarPackage, now: String) -> Begin? {
        guard let key = AnnotationIndex.resolve(id: id, in: package)?.id else { return nil }
        var superseded: [(token: NoteEditToken, result: NoteEditResult)] = []
        for token in edits.filter({ $0.value.key == key }).map(\.key) {
            if let result = end(token, package: &package, now: now) { superseded.append((token, result)) }
        }
        // Finishing a blank standalone note removes it.
        guard let baseline = NoteState.capture(id: key, package: package) else { return nil }
        let token = NoteEditToken()
        edits[token] = Edit(key: key, baseline: baseline, newNoteID: baseline.noteID ?? newNoteID, knownBody: baseline.note?.body)
        return Begin(token: token, superseded: superseded)
    }

    @discardableResult
    public mutating func queue(_ token: NoteEditToken, body: String) -> Bool {
        guard edits[token] != nil else { return false }
        edits[token]?.pending = body
        return true
    }

    /// Writes pending typing into the package. A cleared note stays, blank, until its edit ends.
    @discardableResult
    public mutating func flush(package: inout SidecarPackage, now: String) -> Bool {
        var changed = false
        for token in edits.keys {
            if apply(token, package: &package, now: now) { changed = true }
        }
        return changed
    }

    /// Finishes an edit: writes pending typing and drops the note when it is empty.
    public mutating func end(_ token: NoteEditToken, package: inout SidecarPackage, now: String) -> NoteEditResult? {
        guard edits[token] != nil else { return nil }
        var changed = apply(token, package: &package, now: now)
        guard let edit = edits.removeValue(forKey: token) else { return nil }
        if Self.pruneBlank(edit.key, package: &package) { changed = true }
        let current = NoteState.capture(id: edit.key, package: package)
        let differs = current?.note?.body != edit.baseline.note?.body
        return NoteEditResult(changed: changed, undo: differs ? edit.baseline : nil)
    }

    /// Call before removing annotations. Keeps the latest typed text in the package, so undoing the
    /// removal brings it back, and revokes the editors so nothing can re-create what is removed.
    public mutating func prepareRemoval(ids: Set<String>, package: inout SidecarPackage, now: String) -> (revoked: [NoteEditToken], changed: Bool) {
        let keys = Set(ids.map { AnnotationIndex.resolve(id: $0, in: package)?.id ?? $0 })
        var revoked: [NoteEditToken] = []
        var changed = false
        for token in edits.filter({ keys.contains($0.value.key) }).map(\.key) {
            if let pending = edits[token]?.pending, AnnotationEdit.isBlankNote(pending) { edits[token]?.pending = nil }
            if apply(token, package: &package, now: now) { changed = true }
            guard let edit = edits.removeValue(forKey: token) else { continue }
            revoked.append(token)
            if NoteState.capture(id: edit.key, package: package)?.note != nil { continue }
            if edit.baseline.note != nil {
                edit.baseline.restore(into: &package)
                changed = true
            } else if Self.pruneBlank(edit.key, package: &package) {
                changed = true
            }
        }
        return (revoked, changed)
    }

    /// Revokes editors whose note was changed or removed by something else (undo, a vault reload).
    public mutating func revokeStale(package: SidecarPackage) -> [NoteEditToken] {
        let stale = edits.filter { _, edit in
            guard let current = NoteState.capture(id: edit.key, package: package) else { return true }
            if edit.baseline.highlightID != nil, current.highlightID == nil { return true }
            return current.note?.body != edit.knownBody
        }.map(\.key)
        for token in stale { edits[token] = nil }
        return stale
    }

    private mutating func apply(_ token: NoteEditToken, package: inout SidecarPackage, now: String) -> Bool {
        guard var edit = edits[token], let pending = edit.pending else { return false }
        edit.pending = nil
        defer { edits[token] = edit }
        guard let item = AnnotationIndex.resolve(id: edit.key, in: package) else { return false }
        let text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        var noteID = item.note?.id
        if noteID == nil {
            guard let highlight = item.highlight, !AnnotationEdit.isBlankNote(text) else { return false }
            AnnotationEdit.addNote(toHighlight: highlight.id, noteID: edit.newNoteID, now: now, package: &package)
            noteID = package.highlights.highlights.first { $0.id == highlight.id }?.noteID
        }
        guard let index = package.notes.notes.firstIndex(where: { $0.id == noteID }),
              package.notes.notes[index].body != text else { return false }
        package.notes.notes[index].body = text
        package.notes.notes[index].updated = now
        edit.knownBody = AnnotationEdit.isBlankNote(text) ? nil : text
        return true
    }

    private static func pruneBlank(_ key: String, package: inout SidecarPackage) -> Bool {
        guard let note = AnnotationIndex.resolve(id: key, in: package)?.note, AnnotationEdit.isBlankNote(note.body) else { return false }
        AnnotationEdit.removeNote(id: note.id, package: &package)
        return true
    }
}
