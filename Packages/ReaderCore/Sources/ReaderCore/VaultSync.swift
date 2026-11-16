import Foundation

public struct VaultSyncState: Equatable, Sendable {
    public var disk: String
    public var pending: [String: String]
    public var written: [String: String]

    public init(disk: String, pending: [String: String] = [:], written: [String: String] = [:]) {
        self.disk = disk
        self.pending = pending
        self.written = written
    }
}

public enum VaultSync {
    /// External edit of a hand-written file. Reader's unsaved blocks are merged by id.
    /// If both sides changed the same block, both bodies are kept and the id is flagged.
    public static func applyExternal(_ state: VaultSyncState, disk newDisk: String) -> (state: VaultSyncState, conflicts: [String]) {
        if newDisk == state.disk { return (state, []) }
        var output = newDisk
        var conflicts: [String] = []
        for (id, pendingBody) in state.pending.sorted(by: { $0.key < $1.key }) {
            let remote = OwnedBlocks.body(id: id, in: newDisk)
            let baseline = state.written[id]
            let readerChanged = pendingBody != baseline
            let diskChanged = remote != baseline
            if readerChanged && diskChanged && remote != pendingBody {
                conflicts.append(id)
                let combined = pendingBody + "\n\n> [!warning] Also changed outside Reader\n>\n> " + (remote ?? "").replacingOccurrences(of: "\n", with: "\n> ")
                output = OwnedBlocks.upsert(output, id: id, body: combined)
            } else if readerChanged {
                output = OwnedBlocks.upsert(output, id: id, body: pendingBody)
            }
        }
        var next = state
        next.disk = output
        return (next, conflicts)
    }

    public static func isOwnWrite(newDisk: String, lastWritten: String?) -> Bool {
        guard let lastWritten else { return false }
        return newDisk == lastWritten
    }
}
