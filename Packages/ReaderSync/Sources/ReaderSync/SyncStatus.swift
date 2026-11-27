import Foundation

/// Chip states from `spec/tokens.json` v2. Priority is the only order that matters.
public enum SyncChipState: String, Equatable, Sendable, CaseIterable {
    case error
    case storageFull
    case conflict
    case offline
    case syncing
    case synced

    public static let priority: [SyncChipState] = [
        .error, .storageFull, .conflict, .offline, .syncing, .synced,
    ]

    public var dotHex: String {
        switch self {
        case .synced: return "27AE60"
        case .syncing: return "2F80ED"
        case .offline: return "8E8E93"
        case .conflict: return "F2994A"
        case .error, .storageFull: return "EB5757"
        }
    }

    public func label(conflictCount: Int = 0, waitingBookCount: Int = 0) -> String {
        switch self {
        case .synced: return "Synced"
        case .syncing: return "Syncing…"
        case .offline: return "Offline, changes saved"
        case .conflict:
            let n = max(conflictCount, 1)
            return n == 1 ? "1 version to review" : "\(n) versions to review"
        case .error: return "Can't reach Mac mini"
        case .storageFull: return "Mac mini is full"
        }
    }

    public var detail: String? {
        switch self {
        case .storageFull: return "Books paused. Highlights and notes still sync."
        default: return nil
        }
    }

    public var action: String? {
        switch self {
        case .error: return "Retry"
        case .storageFull: return "Check again"
        default: return nil
        }
    }

    public var bookBadge: String? {
        self == .storageFull ? "Waiting for space" : nil
    }

    public var animates: Bool { self == .syncing }

    /// Picks the highest-priority active condition. `error` beats `storageFull` beats `conflict`, etc.
    public static func resolve(
        unreachable: Bool,
        storageFull: Bool,
        conflictCount: Int,
        offline: Bool,
        syncing: Bool
    ) -> SyncChipState {
        if unreachable { return .error }
        if storageFull { return .storageFull }
        if conflictCount > 0 { return .conflict }
        if offline { return .offline }
        if syncing { return .syncing }
        return .synced
    }
}

public struct SyncStatusSnapshot: Equatable, Sendable {
    public var state: SyncChipState
    public var conflictCount: Int
    public var waitingBookCount: Int
    public var lastError: String?
    public var hostCaption: String
    public var isPaired: Bool

    public init(
        state: SyncChipState,
        conflictCount: Int = 0,
        waitingBookCount: Int = 0,
        lastError: String? = nil,
        hostCaption: String = "",
        isPaired: Bool = false
    ) {
        self.state = state
        self.conflictCount = conflictCount
        self.waitingBookCount = waitingBookCount
        self.lastError = lastError
        self.hostCaption = hostCaption
        self.isPaired = isPaired
    }

    public var label: String { state.label(conflictCount: conflictCount, waitingBookCount: waitingBookCount) }
    public var detail: String? { state.detail }
    public var action: String? { state.action }
    public var bookBadge: String? { state.bookBadge }
}
