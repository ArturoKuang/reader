import Foundation

public struct AnnotationAnchor: Equatable, Sendable {
    public var text: String
    public var page: Int?
    public var cfi: String?
    public var section: String?
    public var prefix: String
    public var suffix: String
    public var rects: [[Double]]

    public init(text: String, page: Int? = nil, cfi: String? = nil, section: String? = nil, prefix: String = "", suffix: String = "", rects: [[Double]] = []) {
        self.text = text
        self.page = page
        self.cfi = cfi
        self.section = section
        self.prefix = prefix
        self.suffix = suffix
        self.rects = rects
    }
}

/// A highlight and the note attached to it, or a legacy note that has no highlight.
public struct Annotation: Equatable, Sendable, Identifiable {
    public var highlight: HighlightEntry?
    public var note: NoteEntry?

    public init(highlight: HighlightEntry?, note: NoteEntry?) {
        self.highlight = highlight
        self.note = note
    }

    public var id: String { highlight?.id ?? note?.id ?? "" }
    public var quote: String { highlight?.quote ?? note?.quote ?? "" }
    public var body: String { note?.body ?? "" }
    public var color: Int { highlight?.color ?? 1 }
    public var page: Int? { highlight?.page ?? note?.page }
    public var cfi: String? { highlight?.cfi ?? note?.cfi }
    public var section: String? {
        let value = highlight?.section ?? note?.section
        if let value, !value.isEmpty { return value }
        return nil
    }
    public var rects: [[Double]] { highlight?.rects ?? [] }
    public var ai: Bool { note?.ai ?? false }
    public var editedAt: String { note?.updated ?? note?.created ?? "" }
    public var hasNote: Bool { note != nil }
}

public enum AnnotationKind: Equatable, Sendable {
    case all
    case notes
    case color(Int)
}

public enum AnnotationSort: Equatable, Sendable {
    case position
    case recentlyEdited
}

public struct AnnotationGroup: Equatable, Sendable, Identifiable {
    public var title: String
    public var items: [Annotation]
    public var id: String { title }
}

public struct AnnotationCounts: Equatable, Sendable {
    public var notes: Int
    public var colors: [Int: Int]

    public init(notes: Int, colors: [Int: Int]) {
        self.notes = notes
        self.colors = colors
    }
}

public enum AnnotationIndex {
    public static func items(highlights: [HighlightEntry], notes: [NoteEntry]) -> [Annotation] {
        var notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var usedNotes = Set<String>()
        var joined: [Annotation] = []
        for highlight in highlights {
            let note = highlight.noteID.flatMap { notesByID[$0] }
            if let note { usedNotes.insert(note.id) }
            joined.append(Annotation(highlight: highlight, note: note))
        }
        for note in notes where !usedNotes.contains(note.id) {
            joined.append(Annotation(highlight: nil, note: note))
        }
        return sort(joined, .position)
    }

    public static func grouped(_ items: [Annotation]) -> [AnnotationGroup] {
        var groups: [AnnotationGroup] = []
        for item in items {
            let title = item.section ?? item.page.map { "Page \($0)" } ?? "Notes"
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].items.append(item)
            } else {
                groups.append(AnnotationGroup(title: title, items: [item]))
            }
        }
        return groups
    }

    public static func filter(_ items: [Annotation], query: String) -> [Annotation] {
        let needle = fold(query)
        if needle.isEmpty { return items }
        return items.filter { fold($0.quote).contains(needle) || fold($0.body).contains(needle) }
    }

    public static func filter(_ items: [Annotation], kind: AnnotationKind) -> [Annotation] {
        switch kind {
        case .all: return items
        case .notes: return items.filter(\.hasNote)
        case .color(let color): return items.filter { $0.highlight?.color == color }
        }
    }

    public static func counts(_ items: [Annotation]) -> AnnotationCounts {
        var colors: [Int: Int] = [:]
        for item in items {
            guard let color = item.highlight?.color else { continue }
            colors[color, default: 0] += 1
        }
        return AnnotationCounts(notes: items.filter(\.hasNote).count, colors: colors)
    }

    public static func sort(_ items: [Annotation], _ order: AnnotationSort) -> [Annotation] {
        switch order {
        case .position:
            return items.sorted { positionKey($0) < positionKey($1) }
        case .recentlyEdited:
            return items.sorted { lhs, rhs in
                if lhs.editedAt.isEmpty != rhs.editedAt.isEmpty { return !lhs.editedAt.isEmpty }
                if lhs.editedAt != rhs.editedAt { return lhs.editedAt > rhs.editedAt }
                return positionKey(lhs) < positionKey(rhs)
            }
        }
    }

    public static func nearest(_ items: [Annotation], to page: Int) -> Annotation? {
        let positioned = items.filter { $0.page != nil }
        guard let best = positioned.min(by: { abs(($0.page ?? page) - page) < abs(($1.page ?? page) - page) }) else {
            return items.first
        }
        return best
    }

    /// The highlight already covering this exact passage, if any.
    public static func highlight(matchingQuote quote: String, page: Int?, cfi: String?, in highlights: [HighlightEntry]) -> HighlightEntry? {
        highlights.first { $0.quote == quote && $0.page == page && $0.cfi == cfi }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Page, then top-of-page first (PDF y grows upward), then x. EPUB uses spine index and CFI offset.
    private static func positionKey(_ item: Annotation) -> (Int, Int, Int, Double, Double) {
        let cfi = item.cfi.flatMap { EPUBCFI(value: $0) }
        let page = item.page ?? Int.max
        let spine = cfi?.spineIndex ?? (item.page == nil ? Int.max : 0)
        let offset = cfi?.startOffset ?? 0
        let rect = item.rects.first
        let top = rect.flatMap { $0.count > 3 ? $0[3] : nil } ?? 0
        let x = rect?.first ?? 0
        return (page == Int.max ? spine : page, page == Int.max ? offset : 0, 0, -top, x)
    }
}

public enum AnnotationEdit {
    private static let placeholders: Set<String> = ["Write a note…", "Write a note...", "Add Note"]

    @discardableResult
    public static func addHighlight(selection: AnnotationAnchor, color: Int, id: String, package: inout SidecarPackage) -> HighlightEntry? {
        guard HighlightPalette.isValid(color), !selection.text.isEmpty else { return nil }
        if let existing = AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, in: package.highlights.highlights) {
            return existing
        }
        let entry = HighlightEntry(
            id: id,
            color: color,
            page: selection.page,
            cfi: selection.cfi,
            quote: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            section: selection.section,
            rects: selection.rects
        )
        package.highlights.highlights.append(entry)
        package.state.lastHighlightColor = color
        return entry
    }

    public static func addNote(toSelection selection: AnnotationAnchor, color: Int, highlightID: String?, noteID: String, now: String, package: inout SidecarPackage) -> Annotation {
        let chosen = HighlightPalette.isValid(color) ? color : package.state.lastHighlightColor
        if highlightID == nil {
            let note = NoteEntry(
                id: noteID,
                page: selection.page,
                cfi: selection.cfi,
                quote: selection.text,
                prefix: selection.prefix,
                suffix: selection.suffix,
                section: selection.section,
                created: now,
                body: ""
            )
            package.notes.notes.append(note)
            return Annotation(highlight: nil, note: note)
        }
        if let existing = AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, in: package.highlights.highlights) {
            let linked = existing.noteID ?? noteID
            addNote(toHighlight: existing.id, noteID: linked, now: now, package: &package)
            let note = package.notes.notes.first { $0.id == linked }
            let highlight = package.highlights.highlights.first { $0.id == existing.id }
            return Annotation(highlight: highlight, note: note)
        }
        let note = NoteEntry(
            id: noteID,
            page: selection.page,
            cfi: selection.cfi,
            quote: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            section: selection.section,
            created: now,
            body: ""
        )
        let highlight = HighlightEntry(
            id: highlightID ?? noteID,
            color: chosen,
            page: selection.page,
            cfi: selection.cfi,
            quote: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            section: selection.section,
            rects: selection.rects,
            noteID: noteID
        )
        package.highlights.highlights.append(highlight)
        package.notes.notes.append(note)
        package.state.lastHighlightColor = chosen
        return Annotation(highlight: highlight, note: note)
    }

    @discardableResult
    public static func addNote(toHighlight id: String, noteID: String, now: String, package: inout SidecarPackage) -> Bool {
        guard let index = package.highlights.highlights.firstIndex(where: { $0.id == id }) else { return false }
        if let linked = package.highlights.highlights[index].noteID, package.notes.notes.contains(where: { $0.id == linked }) {
            return true
        }
        let highlight = package.highlights.highlights[index]
        let note = NoteEntry(
            id: noteID,
            page: highlight.page,
            cfi: highlight.cfi,
            quote: highlight.quote,
            prefix: highlight.prefix,
            suffix: highlight.suffix,
            section: highlight.section,
            created: now,
            body: ""
        )
        package.notes.notes.append(note)
        package.highlights.highlights[index].noteID = noteID
        return true
    }

    public static func updateNoteBody(id: String, body: String, now: String, package: inout SidecarPackage) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = package.notes.notes.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty || placeholders.contains(trimmed) {
            package.notes.notes.remove(at: index)
            for highlightIndex in package.highlights.highlights.indices where package.highlights.highlights[highlightIndex].noteID == id {
                package.highlights.highlights[highlightIndex].noteID = nil
            }
            return
        }
        package.notes.notes[index].body = trimmed
        package.notes.notes[index].updated = now
    }

    public static func removeNote(id: String, package: inout SidecarPackage) {
        package.notes.notes.removeAll { $0.id == id }
        for index in package.highlights.highlights.indices where package.highlights.highlights[index].noteID == id {
            package.highlights.highlights[index].noteID = nil
        }
    }

    public static func removeHighlightAndNote(id: String, package: inout SidecarPackage) {
        let noteID = package.highlights.highlights.first { $0.id == id }?.noteID
        package.highlights.highlights.removeAll { $0.id == id }
        if let noteID {
            package.notes.notes.removeAll { $0.id == noteID }
        } else {
            package.notes.notes.removeAll { $0.id == id }
        }
    }

    /// Drops every selected annotation. Remaining highlights and notes keep their relative order.
    /// A highlight takes its linked note with it. Passing the previous arrays to `restore` puts the batch back.
    public static func remove(ids: Set<String>, package: inout SidecarPackage) {
        guard !ids.isEmpty else { return }
        var linkedNotes = Set<String>()
        for highlight in package.highlights.highlights where ids.contains(highlight.id) {
            if let noteID = highlight.noteID { linkedNotes.insert(noteID) }
        }
        package.highlights.highlights.removeAll { ids.contains($0.id) }
        package.notes.notes.removeAll { ids.contains($0.id) || linkedNotes.contains($0.id) }
    }

    public static func restore(highlights: [HighlightEntry], notes: [NoteEntry], package: inout SidecarPackage) {
        package.highlights.highlights = highlights
        package.notes.notes = notes
    }

    public static func recolor(ids: Set<String>, color: Int, package: inout SidecarPackage) {
        guard HighlightPalette.isValid(color) else { return }
        for index in package.highlights.highlights.indices where ids.contains(package.highlights.highlights[index].id) {
            package.highlights.highlights[index].color = color
        }
        package.state.lastHighlightColor = color
    }

    public static func recolor(id: String, color: Int, package: inout SidecarPackage) {
        guard HighlightPalette.isValid(color), let index = package.highlights.highlights.firstIndex(where: { $0.id == id }) else { return }
        package.highlights.highlights[index].color = color
        package.state.lastHighlightColor = color
    }
}

public enum AnnotationExport {
    public static func markdown(book: String, items: [Annotation], path: String = "") -> String {
        var lines = ["# Notes — \(book)", ""]
        for group in AnnotationIndex.grouped(items) {
            lines.append("## \(group.title)")
            lines.append("")
            for item in group.items {
                let id = item.id
                let location = item.cfi ?? item.page.map { "page=\($0)" }
                let link = ReaderLink(path: path, location: location, id: id)
                let block = VaultNoteBlock(
                    id: id,
                    quote: item.quote,
                    body: item.body,
                    color: item.highlight == nil ? nil : item.color,
                    link: link
                )
                lines.append(block.markdown())
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum HighlightAppearance {
    public static let blendMode = "multiply"
    public static let opacity = 0.38
    /// Dark Aqua uses deeper swatches so a multiply blend stays visible on a black page.
    public static let darkHex = ["E0B400", "3DDC84", "3DB7E8", "E86A9A", "C46BE0", "E8873A"]

    public static func components(color: Int, dark: Bool) -> (r: Double, g: Double, b: Double, a: Double)? {
        let source = dark ? darkHex : HighlightPalette.hex
        guard HighlightPalette.isValid(color), let value = Int(source[color - 1], radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xff) / 255,
            Double((value >> 8) & 0xff) / 255,
            Double(value & 0xff) / 255,
            opacity
        )
    }
}

public enum CopyLink {
    /// A reader:// link for the current selection, including the quote so the passage can be found again.
    public static func make(path: String, page: Int?, cfi: String?, quote: String) -> ReaderLink {
        var location = cfi ?? page.map { "page=\($0)" } ?? ""
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            location = location.isEmpty ? "quote=\(trimmed)" : location + "&quote=\(trimmed)"
        }
        return ReaderLink(path: path, location: location.isEmpty ? nil : location)
    }
}

public enum VaultAnnotationSync {
    /// One block per highlight, using the highlight's id, with the linked note's body inside it.
    /// A note that has no highlight keeps its own id. `removeIDs` are Reader blocks to drop.
    public static func render(existing: String, bookPath: String, annotations: [Annotation], removeIDs: Set<String> = []) -> String {
        var blocks: [VaultNoteBlock] = []
        for item in annotations {
            if let highlight = item.highlight {
                let location = highlight.cfi ?? highlight.page.map { "page=\($0)" }
                blocks.append(VaultNoteBlock(
                    id: highlight.id,
                    quote: highlight.quote,
                    body: item.note?.body ?? "",
                    color: highlight.color,
                    link: ReaderLink(path: bookPath, location: location, id: highlight.id),
                    chapter: item.section.flatMap { ChapterFiles.number(in: $0) }
                ))
            } else if let note = item.note {
                let location = note.cfi ?? note.page.map { "page=\($0)" }
                blocks.append(VaultNoteBlock(
                    id: note.id,
                    quote: note.quote,
                    body: note.body,
                    color: nil,
                    link: ReaderLink(path: bookPath, location: location, id: note.id)
                ))
            }
        }
        var text = VaultNoteFile.upsertPreservingLocations(existing, blocks: blocks)
        for id in removeIDs where !blocks.contains(where: { $0.id == id }) {
            text = OwnedBlocks.remove(text, id: id)
        }
        return text
    }
}
