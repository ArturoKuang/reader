import Foundation

public enum FindSelection {
    /// The first match whose start is at or after `cursor`.
    /// A cursor of 0, or a cursor sitting on the first match, selects that match — not the one after it.
    /// When every match is before the cursor, wrap to the first match in the document.
    public static func index(starts: [Int], cursor: Int) -> Int? {
        guard !starts.isEmpty else { return nil }
        if let index = starts.firstIndex(where: { $0 >= cursor }) { return index }
        return 0
    }

    /// Move to the following match. `current` is the match already on screen.
    public static func step(count: Int, current: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        if forward { return (current + 1) % count }
        return (current - 1 + count) % count
    }
}

public enum FindCommand: Equatable, Sendable {
    /// The query changed, or there are no matches yet. Select the first hit.
    case begin
    /// Return on a query the toolbar already searched. Leave the current hit selected.
    case stay
    /// A later Return. Move to the next match.
    case step
}

public enum FindQuery {
    /// Live search calls this on every edit and again when Return is pressed.
    /// The first Return after a query already has matches stays put. Only a Return after that advances.
    /// `committed` is true once Return has accepted this exact query.
    public static func command(query: String, previous: String, hasMatches: Bool, committed: Bool) -> FindCommand {
        if query != previous || !hasMatches {
            return .begin
        }
        if !committed {
            return .stay
        }
        return .step
    }
}
