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

/// A live PDF note stores the page and leaves `cfi` nil. The vault writes that page as `page=N`.
public enum PassageIdentity {
    public static func cfi(_ location: String?) -> String? {
        guard let location, !location.isEmpty, !location.hasPrefix("page=") else { return nil }
        return location
    }

    public static func same(quote: String, page: Int?, cfi: String?, otherQuote: String, otherPage: Int?, otherCFI: String?) -> Bool {
        quote == otherQuote && page == otherPage && self.cfi(cfi) == self.cfi(otherCFI)
    }
}

public enum AnnotationIndex {
    public static func items(highlights: [HighlightEntry], notes: [NoteEntry]) -> [Annotation] {
        let notesByID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var usedNotes = Set<String>()
        var joined: [Annotation] = []
        for highlight in highlights {
            let note = highlight.noteID.flatMap { notesByID[$0] }
            if let note { usedNotes.insert(note.id) }
            joined.append(Annotation(highlight: highlight, note: note))
        }
        for note in notes where !usedNotes.contains(note.id) {
            if let index = joined.firstIndex(where: { samePassage($0, as: note) && $0.highlight != nil }) {
                if joined[index].note == nil {
                    joined[index] = Annotation(highlight: joined[index].highlight, note: note)
                }
                continue
            }
            joined.append(Annotation(highlight: nil, note: note))
        }
        return sort(joined, .position)
    }

    /// A highlight and a note written again under the highlight's id describe one passage.
    private static func samePassage(_ item: Annotation, as note: NoteEntry) -> Bool {
        PassageIdentity.same(quote: item.quote, page: item.page, cfi: item.cfi, otherQuote: note.quote, otherPage: note.page, otherCFI: note.cfi)
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

    /// The annotation an id refers to: a highlight id, a standalone note id, or a linked note id.
    public static func resolve(id: String, highlights: [HighlightEntry], notes: [NoteEntry]) -> Annotation? {
        let all = items(highlights: highlights, notes: notes)
        return all.first { $0.id == id } ?? all.first { $0.note?.id == id || $0.highlight?.noteID == id }
    }

    public static func resolve(id: String, in package: SidecarPackage) -> Annotation? {
        resolve(id: id, highlights: package.highlights.highlights, notes: package.notes.notes)
    }

    /// `items` in the order of `ids`, so rows hold still while one of them is edited.
    /// Items `ids` does not name follow in their own order.
    public static func holding(_ items: [Annotation], order ids: [String]) -> [Annotation] {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            (rank[lhs.element.id] ?? ids.count, lhs.offset) < (rank[rhs.element.id] ?? ids.count, rhs.offset)
        }.map(\.element)
    }

    /// The highlight already covering this exact passage, if any. A quote can repeat on a page or in a
    /// section, so line rects, and failing those the surrounding text, tell the occurrences apart.
    /// Whatever either side lacks is not compared.
    public static func highlight(matchingQuote quote: String, page: Int?, cfi: String?, rects: [[Double]] = [], prefix: String = "", suffix: String = "", in highlights: [HighlightEntry]) -> HighlightEntry? {
        highlights.first { entry in
            guard PassageIdentity.same(quote: entry.quote, page: entry.page, cfi: entry.cfi, otherQuote: quote, otherPage: page, otherCFI: cfi) else { return false }
            if !rects.isEmpty, !entry.rects.isEmpty { return overlap(rects, entry.rects) }
            // Markdown offsets already name one occurrence.
            if cfi.flatMap({ MarkdownAnchor(value: $0) })?.startOffset != nil { return true }
            return sameContext(entry.prefix, prefix, fromEnd: true) && sameContext(entry.suffix, suffix, fromEnd: false)
        }
    }

    /// Rects are `[minX, minY, maxX, maxY]`. Neighboring lines may touch, so a sliver does not count.
    private static func overlap(_ lhs: [[Double]], _ rhs: [[Double]]) -> Bool {
        lhs.contains { a in
            rhs.contains { b in
                guard a.count >= 4, b.count >= 4 else { return false }
                let width = min(a[2], b[2]) - max(a[0], b[0])
                let height = min(a[3], b[3]) - max(a[1], b[1])
                guard width > 0, height > 0 else { return false }
                let smaller = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
                return width * height > smaller * 0.25
            }
        }
    }

    /// Stored context can be longer than a fresh selection's, so the nearer text must agree.
    private static func sameContext(_ lhs: String, _ rhs: String, fromEnd: Bool) -> Bool {
        let a = lhs.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let b = rhs.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if a.isEmpty || b.isEmpty { return true }
        return fromEnd ? a.hasSuffix(b) || b.hasSuffix(a) : a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Page, then top-of-page first (PDF y grows upward), then x. EPUB uses spine index and CFI offset;
    /// Markdown uses section index and text offset.
    private static func positionKey(_ item: Annotation) -> (Int, Int, Int, Double, Double) {
        let cfi = item.cfi.flatMap { EPUBCFI(value: $0) }
        let markdown = item.cfi.flatMap { MarkdownAnchor(value: $0) }
        let page = item.page ?? Int.max
        let spine = cfi?.spineIndex ?? markdown?.sectionIndex ?? (item.page == nil ? Int.max : 0)
        let offset = cfi?.startOffset ?? markdown?.startOffset ?? 0
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
        if let existing = AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, rects: selection.rects, prefix: selection.prefix, suffix: selection.suffix, in: package.highlights.highlights) {
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
        if let existing = AnnotationIndex.highlight(matchingQuote: selection.text, page: selection.page, cfi: selection.cfi, rects: selection.rects, prefix: selection.prefix, suffix: selection.suffix, in: package.highlights.highlights) {
            // A note attached to a highlight always reuses the highlight's id (spec / Android).
            let linked = existing.noteID ?? existing.id
            addNote(toHighlight: existing.id, noteID: linked, now: now, package: &package)
            let note = package.notes.notes.first { $0.id == linked }
            let highlight = package.highlights.highlights.first { $0.id == existing.id }
            return Annotation(highlight: highlight, note: note)
        }
        // New highlight + note: both records share the highlight id, even if the
        // caller passed a different noteID.
        let hid = highlightID ?? noteID
        let note = NoteEntry(
            id: hid,
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
            id: hid,
            color: chosen,
            page: selection.page,
            cfi: selection.cfi,
            quote: selection.text,
            prefix: selection.prefix,
            suffix: selection.suffix,
            section: selection.section,
            rects: selection.rects,
            noteID: hid
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
        // New notes on a highlight reuse the highlight id (spec / Android).
        let resolvedNoteID = highlight.noteID ?? highlight.id
        let note = NoteEntry(
            id: resolvedNoteID,
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
        package.highlights.highlights[index].noteID = resolvedNoteID
        return true
    }

    /// Removes a note that repeats a highlight's passage after the note was saved under the highlight's id.
    public static func dropDuplicateNotes(highlights: inout [HighlightEntry], notes: inout [NoteEntry]) {
        notes.removeAll { note in
            // With a repeated quote, the first matching passage may belong to another note.
            if highlights.contains(where: { $0.noteID == note.id }) { return false }
            guard let highlight = highlights.first(where: {
                PassageIdentity.same(quote: $0.quote, page: $0.page, cfi: $0.cfi, otherQuote: note.quote, otherPage: note.page, otherCFI: note.cfi)
            }) else { return false }
            return highlight.noteID != nil
        }
    }

    /// Empty, whitespace, or only a placeholder.
    public static func isBlankNote(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || placeholders.contains(trimmed)
    }

    public static func updateNoteBody(id: String, body: String, now: String, package: inout SidecarPackage) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = package.notes.notes.firstIndex(where: { $0.id == id }) else { return }
        if isBlankNote(trimmed) {
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

    /// Removes the note behind a highlight or note id. A highlight stays.
    public static func removeNoteOnly(id: String, package: inout SidecarPackage) {
        guard let note = AnnotationIndex.resolve(id: id, in: package)?.note else { return }
        removeNote(id: note.id, package: &package)
    }

    /// Removes the highlight and note behind either one's id.
    public static func removeAnnotation(id: String, package: inout SidecarPackage) {
        remove(ids: [id], package: &package)
    }

    /// Drops every selected annotation. Remaining highlights and notes keep their relative order.
    /// A highlight takes its linked note with it. Passing the previous arrays to `restore` puts the batch back.
    public static func remove(ids: Set<String>, package: inout SidecarPackage) {
        guard !ids.isEmpty else { return }
        var highlightIDs = Set<String>()
        var noteIDs = ids
        for id in ids {
            guard let item = AnnotationIndex.resolve(id: id, in: package) else { continue }
            if let highlight = item.highlight { highlightIDs.insert(highlight.id) }
            if let noteID = item.highlight?.noteID { noteIDs.insert(noteID) }
            if let noteID = item.note?.id { noteIDs.insert(noteID) }
        }
        package.highlights.highlights.removeAll { highlightIDs.contains($0.id) }
        package.notes.notes.removeAll { noteIDs.contains($0.id) }
    }

    public static func restore(highlights: [HighlightEntry], notes: [NoteEntry], package: inout SidecarPackage) {
        package.highlights.highlights = highlights
        package.notes.notes = notes
    }

    public static func recolor(ids: Set<String>, color: Int, package: inout SidecarPackage) {
        guard HighlightPalette.isValid(color) else { return }
        let highlightIDs = Set(ids.compactMap { AnnotationIndex.resolve(id: $0, in: package)?.highlight?.id })
        for index in package.highlights.highlights.indices where highlightIDs.contains(package.highlights.highlights[index].id) {
            package.highlights.highlights[index].color = color
        }
        package.state.lastHighlightColor = color
    }

    /// `id` may be the highlight's or its note's. A standalone note has no color to change.
    public static func recolor(id: String, color: Int, package: inout SidecarPackage) {
        guard HighlightPalette.isValid(color),
              let highlightID = AnnotationIndex.resolve(id: id, in: package)?.highlight?.id else { return }
        recolor(ids: [highlightID], color: color, package: &package)
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

public enum MarginLayout {
    /// Sort by vertical position and push a card down when it would cover the one above.
    /// `y` is the bottom of the card in a y-up coordinate space. Higher cards stay put; the next card moves down.
    public static func stack(_ cards: [(id: String, y: Double)], height: Double, gap: Double = 4) -> [(id: String, y: Double)] {
        let sorted = cards.sorted { lhs, rhs in
            if lhs.y == rhs.y { return lhs.id < rhs.id }
            return lhs.y > rhs.y
        }
        var placed: [(id: String, y: Double)] = []
        var nextTop = Double.greatestFiniteMagnitude
        for card in sorted {
            let top = min(card.y + height, nextTop)
            let y = top - height
            placed.append((card.id, y))
            nextTop = y - gap
        }
        return placed
    }
}

public enum BookmarkEdit {
    public static func matches(_ bookmark: Bookmark, page: Int?, cfi: String?) -> Bool {
        if let cfi, let stored = bookmark.cfi, stored == cfi { return true }
        if let page, bookmark.page == page { return true }
        return false
    }

    /// Returns the bookmark that was added, or nil when an existing one was removed.
    @discardableResult
    public static func toggle(page: Int?, cfi: String?, title: String, section: String?, id: String, bookmarks: inout [Bookmark]) -> Bookmark? {
        if let index = bookmarks.firstIndex(where: { matches($0, page: page, cfi: cfi) }) {
            bookmarks.remove(at: index)
            return nil
        }
        let bookmark = Bookmark(id: id, page: page, cfi: cfi, title: title, section: section)
        bookmarks.append(bookmark)
        return bookmark
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

    public static func css(dark: Bool) -> String {
        (1...6).compactMap { color -> String? in
            guard let part = components(color: color, dark: dark) else { return nil }
            let hex = String(format: "#%02X%02X%02X%02X", intByte(part.r), intByte(part.g), intByte(part.b), intByte(part.a))
            return ".reader-hl-\(color) { background: \(hex); }"
        }.joined(separator: "\n")
    }

    private static func intByte(_ value: Double) -> Int {
        min(255, max(0, Int((value * 255).rounded())))
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
    public static func render(existing: String, bookPath: String, annotations: [Annotation], removeIDs: Set<String> = [], updatingLocations: Bool = false) -> String {
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
                if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
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
        var text = updatingLocations
            ? blocks.reduce(existing) { VaultNoteFile.upsert($0, block: $1) }
            : VaultNoteFile.upsertPreservingLocations(existing, blocks: blocks)
        for id in removeIDs where !blocks.contains(where: { $0.id == id }) {
            text = OwnedBlocks.remove(text, id: id)
        }
        return text
    }

    /// Three-way merge of one note file, block by block. `baseline` is the file as Reader last saw it,
    /// `disk` is the file now, and `annotations` and `removeIDs` are Reader's side. A block changed on
    /// one side takes that side. When both changed the note text, both texts are kept and the id is returned.
    /// Blocks are keyed the way `render` writes them, so a linked note never gets a block of its own.
    public static func merge(baseline: String, disk: String, bookPath: String, annotations: [Annotation], removeIDs: Set<String> = [], updatingLocations: Bool = false) -> (text: String, conflicts: [String]) {
        let mine = render(existing: baseline, bookPath: bookPath, annotations: annotations, removeIDs: removeIDs, updatingLocations: updatingLocations)
        if disk == baseline { return (mine, []) }
        func blocks(_ text: String) -> [String: VaultNoteBlock] {
            Dictionary(VaultNoteFile.blocks(text).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let before = blocks(baseline)
        let theirs = blocks(disk)
        let ours = blocks(mine)
        var output = disk
        var conflicts: [String] = []
        for id in annotations.map(\.id) {
            guard let ourBlock = ours[id] else { continue }
            let base = before[id]
            if ourBlock == base { continue }
            let rendered = OwnedBlocks.body(id: id, in: mine) ?? ourBlock.markdown()
            guard let theirBlock = theirs[id] else {
                // Deleted outside Reader while Reader changed it: keep Reader's text.
                output = OwnedBlocks.upsert(output, id: id, body: rendered)
                continue
            }
            if theirBlock == base {
                output = OwnedBlocks.upsert(output, id: id, body: rendered)
                continue
            }
            var combined = theirBlock
            if ourBlock.color != base?.color { combined.color = ourBlock.color }
            if ourBlock.body != base?.body, ourBlock.body != theirBlock.body {
                if theirBlock.body == base?.body {
                    combined.body = ourBlock.body
                } else {
                    combined.body = [ourBlock.body, "**Also changed outside Reader:**", theirBlock.body]
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                    conflicts.append(id)
                }
            }
            if combined != theirBlock { output = OwnedBlocks.upsert(output, id: id, body: combined.markdown()) }
        }
        for id in removeIDs where ours[id] == nil && theirs[id] == before[id] {
            output = OwnedBlocks.remove(output, id: id)
        }
        return (output, conflicts)
    }

    /// Adds sidecar notes that are not already in the file. Existing block ids are left untouched.
    public static func mergeSidecarOnce(existing: String, bookPath: String, annotations: [Annotation]) -> String {
        let present = Set(VaultNoteFile.blocks(existing).map(\.id))
        let fresh = annotations.filter { !present.contains($0.id) }
        guard !fresh.isEmpty else { return existing }
        return render(existing: existing, bookPath: bookPath, annotations: fresh)
    }
}
