import Foundation
import ReaderCore

public enum ConflictChoice: Equatable, Sendable {
    case keepSide(Int)
    case combineNotes(body: String)
}

public struct PreparedResolution: Sendable {
    public var conflictId: String
    public var request: ResolveRequest
    /// Winning note/highlight to project into the Mac vault. Never a conflict-copy file.
    public var highlight: HighlightEntry?
    public var note: NoteEntry?
}

public enum ConflictResolution {
    /// Build a resolve request. Combining notes keeps the Mac side's highlight color when both sides have one.
    public static func prepare(
        conflict: OpenConflict,
        choice: ConflictChoice,
        macDeviceIds: Set<String>,
        changeId: String = newChangeId()
    ) throws -> PreparedResolution {
        guard !conflict.sides.isEmpty else {
            throw SyncAPIError(status: 0, code: "bad_request", message: "conflict has no sides")
        }
        // Resolve writes head+1; baseVersion must be the current head, not the ancestor.
        let headVersion = currentHeadVersion(conflict)
        switch choice {
        case .keepSide(let index):
            guard conflict.sides.indices.contains(index) else {
                throw SyncAPIError(status: 0, code: "bad_request", message: "that version is gone")
            }
            let side = conflict.sides[index]
            return PreparedResolution(
                conflictId: conflict.conflictId,
                request: ResolveRequest(changeId: changeId, baseVersion: headVersion, deleted: side.deleted, payload: side.payload),
                highlight: highlight(from: conflict, payload: side.payload, deleted: side.deleted),
                note: note(from: conflict, payload: side.payload, deleted: side.deleted)
            )
        case .combineNotes(let body):
            let macIndex = conflict.sides.firstIndex { macDeviceIds.contains($0.deviceId) } ?? 0
            let mac = conflict.sides[macIndex]
            var payload = mac.payload ?? [:]
            payload["body"] = body
            if payload["extras"] == nil { payload["extras"] = [:] }
            // Combined note saves with the Mac highlight color (Designer spec).
            if conflict.kind == .highlight, payload["color"] == nil, let color = macColor(from: conflict, macDeviceIds: macDeviceIds) {
                payload["color"] = color
            }
            return PreparedResolution(
                conflictId: conflict.conflictId,
                request: ResolveRequest(changeId: changeId, baseVersion: headVersion, deleted: false, payload: payload),
                highlight: highlight(from: conflict, payload: payload, deleted: false),
                note: note(from: conflict, payload: payload, deleted: false)
            )
        }
    }

    public static func defaultCombinedBody(conflict: OpenConflict, macDeviceIds: Set<String>) -> String {
        let mac = conflict.sides.first { macDeviceIds.contains($0.deviceId) }
        let other = conflict.sides.first { side in !macDeviceIds.contains(side.deviceId) } ?? conflict.sides.last
        let left = string(mac?.payload, "body")
        let right = string(other?.payload, "body")
        switch (left.isEmpty, right.isEmpty) {
        case (true, true): return ""
        case (false, true): return left
        case (true, false): return right
        default: return left + "\n" + right
        }
    }

    public static func display(side: ConflictSide, devices: [PairedDevice]) -> (name: String, time: String, color: Int, colorName: String, note: String, deleted: Bool) {
        let device = devices.first { $0.deviceId == side.deviceId }
        let color = side.payload?.int("color") ?? 1
        return (
            name: device?.name ?? side.deviceId,
            time: formatTime(side.clientTime),
            color: color,
            colorName: RecordAdapter.highlightColorName(color),
            note: string(side.payload, "body").isEmpty ? string(side.payload, "quote") : string(side.payload, "body"),
            deleted: side.deleted
        )
    }

    public static func currentHeadVersion(_ conflict: OpenConflict) -> Int {
        if let head = conflict.sides.compactMap(\.version).max() {
            return head
        }
        return max(conflict.baseVersion, 1)
    }

    private static func highlight(from conflict: OpenConflict, payload: [String: Any]?, deleted: Bool) -> HighlightEntry? {
        guard conflict.kind == .highlight, !deleted, let payload else { return nil }
        return RecordAdapter.highlight(from: payload, id: conflict.recordId)
    }

    private static func note(from conflict: OpenConflict, payload: [String: Any]?, deleted: Bool) -> NoteEntry? {
        guard conflict.kind == .note, !deleted, let payload else { return nil }
        return RecordAdapter.note(from: payload, id: conflict.recordId)
    }

    private static func macColor(from conflict: OpenConflict, macDeviceIds: Set<String>) -> Int? {
        conflict.sides.first { macDeviceIds.contains($0.deviceId) }?.payload?.int("color")
    }

    private static func string(_ payload: [String: Any]?, _ key: String) -> String {
        payload?.string(key) ?? ""
    }

    private static func formatTime(_ raw: String?) -> String {
        guard let date = parseDate(raw) else { return raw ?? "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
