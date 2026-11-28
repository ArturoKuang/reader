import Foundation

/// Marks a sidecar package that stands in for a vault while saving to the vault is off.
public struct PausedVaultState: Codable, Equatable, Sendable {
    /// True while the package holds edits the vault does not have.
    public var authoritative: Bool
    /// The vault note files as Reader last saw them, by path. The base of the merge when saving resumes.
    public var baseline: [String: String]
    /// Block ids Reader had loaded. One of these missing from the package was deleted while paused.
    public var blockIDs: [String]

    public init(authoritative: Bool, baseline: [String: String] = [:], blockIDs: [String] = []) {
        self.authoritative = authoritative
        self.baseline = baseline
        self.blockIDs = blockIDs
    }

    static let fileName = "vault-paused.json"

    public static func load(directory: String, fs: FileSystem) -> PausedVaultState? {
        guard let data = try? fs.read(Paths.join(directory, fileName)) else { return nil }
        return try? JSONDecoder().decode(PausedVaultState.self, from: data)
    }

    public func save(directory: String, fs: FileSystem) throws {
        try fs.createDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.write(Paths.join(directory, Self.fileName), try encoder.encode(self))
    }
}

extension SidecarPackage {
    /// Adds the highlights, notes, words, and marks that only `other` has. Existing ids win.
    public mutating func mergeAnnotations(from other: SidecarPackage) {
        let highlightIDs = Set(highlights.highlights.map(\.id))
        highlights.highlights += other.highlights.highlights.filter { !highlightIDs.contains($0.id) }
        let noteIDs = Set(notes.notes.map(\.id)).union(highlights.highlights.compactMap { highlight in
            // A vault block names its note after the highlight; do not add the sidecar's copy beside it.
            highlightIDs.contains(highlight.id) ? highlight.noteID : nil
        })
        let linkedElsewhere = Set(other.highlights.highlights.filter { highlightIDs.contains($0.id) }.compactMap(\.noteID))
        notes.notes += other.notes.notes.filter { !noteIDs.contains($0.id) && !linkedElsewhere.contains($0.id) }
        let known = Set(words.words.map { WordStore.normalize($0.word) })
        words.words += other.words.words.filter { !known.contains(WordStore.normalize($0.word)) }
        let markIDs = Set(marks.marks.map(\.id))
        marks.marks += other.marks.marks.filter { !markIDs.contains($0.id) }
    }

    /// Notes that are still empty because they are being typed never reach disk.
    public func pruningBlankNotes() -> SidecarPackage {
        var copy = self
        for note in notes.notes where AnnotationEdit.isBlankNote(note.body) {
            AnnotationEdit.removeNote(id: note.id, package: &copy)
        }
        return copy
    }
}
