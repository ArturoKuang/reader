import Foundation

public struct NavigationHistory: Equatable, Sendable {
    public private(set) var backStack: [ReadingPosition] = []
    public private(set) var forwardStack: [ReadingPosition] = []
    /// Position before the most recent jump. `` ` ` `` swaps with this, vim-style.
    public private(set) var previousJump: ReadingPosition?

    public init() {}

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func jump(from: ReadingPosition, to: ReadingPosition) {
        backStack.append(from)
        forwardStack.removeAll()
        previousJump = from
    }

    public mutating func back(current: ReadingPosition) -> ReadingPosition? {
        guard let destination = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return destination
    }

    public mutating func forward(current: ReadingPosition) -> ReadingPosition? {
        guard let destination = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return destination
    }

    /// `` ` ` `` returns the position from before the last jump, and a second
    /// press returns to where you were. The move is also pushed onto the
    /// back stack so Preview-style Back returns as well.
    public mutating func jumpBack(current: ReadingPosition) -> ReadingPosition? {
        guard let destination = previousJump else { return nil }
        backStack.append(current)
        forwardStack.removeAll()
        previousJump = current
        return destination
    }
}

public enum MarkChord: Equatable, Sendable {
    case idle
    case awaitingSet
    case awaitingJump
}

public struct MarkKey: Equatable, Sendable {
    public var character: String?
    public var isEscape: Bool
    public var hasCommandModifier: Bool
    public var documentFocused: Bool
    public var textInputFocused: Bool

    public init(character: String? = nil, isEscape: Bool = false, hasCommandModifier: Bool = false, documentFocused: Bool, textInputFocused: Bool) {
        self.character = character
        self.isEscape = isEscape
        self.hasCommandModifier = hasCommandModifier
        self.documentFocused = documentFocused
        self.textInputFocused = textInputFocused
    }
}

public enum MarkEffect: Equatable, Sendable {
    case none
    case consume
    case passthrough
    case set(String)
    case jump(String)
    case jumpBack
    case showList
}

public struct MarkJump: Equatable, Sendable {
    public var position: ReadingPosition
    public var bookPath: String?
    public var bookFingerprint: String?
    public var openOtherBook: Bool

    public init(position: ReadingPosition, bookPath: String?, bookFingerprint: String?, openOtherBook: Bool) {
        self.position = position
        self.bookPath = bookPath
        self.bookFingerprint = bookFingerprint
        self.openOtherBook = openOtherBook
    }
}

public struct MarkHandleResult: Equatable, Sendable {
    public var effect: MarkEffect
    public var toast: String?
    public var jump: MarkJump?
    /// When true, the key monitor should pass the event to the document view.
    public var passThrough: Bool

    public init(effect: MarkEffect, toast: String? = nil, jump: MarkJump? = nil, passThrough: Bool = false) {
        self.effect = effect
        self.toast = toast
        self.jump = jump
        self.passThrough = passThrough
    }
}

public enum MarkToast {
    public static func set(_ symbol: String) -> String { "Mark \(symbol) set" }
    public static func jumped(_ symbol: String) -> String { "Jumped to \(symbol)" }
    public static func jumpedBack() -> String { "Jumped back" }
    public static func missing(_ symbol: String) -> String { "No mark \(symbol)" }
}

public struct MarkStore: Equatable, Sendable {
    public var local: [MarkEntry]
    public var global: [MarkEntry]

    public init(local: [MarkEntry] = [], global: [MarkEntry] = []) {
        self.local = local
        self.global = global
    }

    public mutating func set(
        symbol: String,
        position: ReadingPosition,
        bookFingerprint: String,
        bookPath: String,
        title: String,
        now: String,
        id: String
    ) -> MarkEntry {
        let scope = MarkScope.forSymbol(symbol)
        let entry = MarkEntry(
            id: id,
            symbol: symbol,
            scope: scope,
            position: position,
            bookFingerprint: bookFingerprint,
            bookPath: bookPath,
            documentTitle: title,
            setAt: now
        )
        switch scope {
        case .local:
            local.removeAll { $0.symbol == symbol }
            local.append(entry)
        case .global:
            global.removeAll { $0.symbol == symbol }
            global.append(entry)
        }
        return entry
    }

    public func get(symbol: String, bookFingerprint: String) -> MarkEntry? {
        switch MarkScope.forSymbol(symbol) {
        case .local:
            return local.first { $0.symbol == symbol }
        case .global:
            return global.first { $0.symbol == symbol }
        }
    }

    public func sidebarMarks() -> (local: [MarkEntry], global: [MarkEntry]) {
        (
            local.sorted { $0.symbol < $1.symbol },
            global.sorted { $0.symbol < $1.symbol }
        )
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = local.count + global.count
        local.removeAll { $0.id == id }
        global.removeAll { $0.id == id }
        return local.count + global.count != before
    }

    @discardableResult
    public mutating func remove(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        let before = local.count + global.count
        local.removeAll { ids.contains($0.id) }
        global.removeAll { ids.contains($0.id) }
        return local.count + global.count != before
    }
}

public struct MarkListLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var symbol: String
    public var global: Bool
    public var location: String
    public var snippet: String

    public init(id: String, symbol: String, global: Bool, location: String, snippet: String) {
        self.id = id
        self.symbol = symbol
        self.global = global
        self.location = location
        self.snippet = snippet
    }
}

public struct MarkListSection: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var lines: [MarkListLine]

    public init(id: String, title: String, lines: [MarkListLine]) {
        self.id = id
        self.title = title
        self.lines = lines
    }
}

public enum MarkList {
    /// Local marks first, then global marks. Each line is the letter, a page, and one snippet.
    public static func lines(local: [MarkEntry], global: [MarkEntry]) -> [MarkListLine] {
        sections(local: local, global: global).flatMap(\.lines)
    }

    /// "This book" holds lowercase (local) marks. "Other books" holds uppercase
    /// (global) marks, with the book name on the location line.
    public static func sections(local: [MarkEntry], global: [MarkEntry]) -> [MarkListSection] {
        var sections: [MarkListSection] = []
        let thisBook = sidebarSorted(local).map { line($0, global: false) }
        let otherBooks = sidebarSorted(global).map { line($0, global: true) }
        if !thisBook.isEmpty {
            sections.append(MarkListSection(id: "this-book", title: "This book", lines: thisBook))
        }
        if !otherBooks.isEmpty {
            sections.append(MarkListSection(id: "other-books", title: "Other books", lines: otherBooks))
        }
        return sections
    }

    private static func sidebarSorted(_ marks: [MarkEntry]) -> [MarkEntry] {
        marks.sorted { $0.symbol < $1.symbol }
    }

    private static func line(_ mark: MarkEntry, global: Bool) -> MarkListLine {
        let page = mark.position.page.map { "p. \($0)" }
        let location: String
        if global, let book = mark.documentTitle, !book.isEmpty {
            location = page.map { "\(book) · \($0)" } ?? (mark.position.section.map { "\(book) · \($0)" } ?? book)
        } else {
            location = page ?? mark.position.section ?? "—"
        }
        let quote = mark.position.quote?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let section = mark.position.section ?? ""
        var snippet = quote.isEmpty ? section : quote
        if snippet.count > 80 { snippet = String(snippet.prefix(79)) + "…" }
        return MarkListLine(id: mark.id, symbol: mark.symbol, global: global, location: location, snippet: snippet)
    }
}

public enum MarkInput {
    public static func reduce(chord: inout MarkChord, key: MarkKey) -> MarkEffect {
        if key.textInputFocused || !key.documentFocused {
            if chord != .idle { chord = .idle }
            return .none
        }
        if key.hasCommandModifier {
            if chord != .idle {
                chord = .idle
                return .passthrough
            }
            return .none
        }
        if key.isEscape {
            if chord != .idle {
                chord = .idle
                return .consume
            }
            return .none
        }
        switch chord {
        case .idle:
            if key.character == "m" {
                chord = .awaitingSet
                return .consume
            }
            if key.character == "`" || key.character == "'" {
                chord = .awaitingJump
                return .consume
            }
            return .none
        case .awaitingSet:
            guard let symbol = printable(key.character) else {
                chord = .idle
                return .passthrough
            }
            chord = .idle
            return .set(symbol)
        case .awaitingJump:
            guard let symbol = printable(key.character) else {
                chord = .idle
                return .passthrough
            }
            chord = .idle
            if symbol == "`" || symbol == "'" { return .jumpBack }
            if symbol == "?" { return .showList }
            return .jump(symbol)
        }
    }

    private static func printable(_ character: String?) -> String? {
        guard let character, character.count == 1, let scalar = character.unicodeScalars.first else { return nil }
        if scalar.value < 0x20 || scalar == "\u{7f}" { return nil }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
        return character
    }
}

public enum MarkController {
    public static func handle(
        chord: inout MarkChord,
        key: MarkKey,
        store: inout MarkStore,
        current: ReadingPosition,
        history: inout NavigationHistory,
        bookFingerprint: String,
        bookPath: String,
        title: String,
        now: String,
        makeID: () -> String
    ) -> MarkHandleResult {
        let effect = MarkInput.reduce(chord: &chord, key: key)
        switch effect {
        case .none:
            return MarkHandleResult(effect: effect, passThrough: true)
        case .consume:
            return MarkHandleResult(effect: effect)
        case .passthrough:
            return MarkHandleResult(effect: effect, passThrough: true)
        case .set(let symbol):
            _ = store.set(symbol: symbol, position: current, bookFingerprint: bookFingerprint, bookPath: bookPath, title: title, now: now, id: makeID())
            return MarkHandleResult(effect: effect, toast: MarkToast.set(symbol))
        case .jump(let symbol):
            guard let mark = store.get(symbol: symbol, bookFingerprint: bookFingerprint) else {
                return MarkHandleResult(effect: effect, toast: MarkToast.missing(symbol))
            }
            let other = mark.scope == .global && mark.bookFingerprint != bookFingerprint
            if !other {
                history.jump(from: current, to: mark.position)
            }
            return MarkHandleResult(
                effect: effect,
                toast: MarkToast.jumped(symbol),
                jump: MarkJump(
                    position: mark.position,
                    bookPath: mark.bookPath,
                    bookFingerprint: mark.bookFingerprint,
                    openOtherBook: other
                )
            )
        case .showList:
            return MarkHandleResult(effect: effect, toast: "Marks")
        case .jumpBack:
            guard let destination = history.jumpBack(current: current) else {
                return MarkHandleResult(effect: effect, toast: "No earlier position")
            }
            return MarkHandleResult(
                effect: effect,
                toast: MarkToast.jumpedBack(),
                jump: MarkJump(position: destination, bookPath: bookPath, bookFingerprint: bookFingerprint, openOtherBook: false)
            )
        }
    }
}

/// Local marks for a vault book. They stay in Application Support, not in the vault's notes.
public enum BookMarks {
    public static func path(applicationSupport: String, fingerprint: String) -> String {
        let safe = fingerprint
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return Paths.join(applicationSupport, "book-marks/\(safe).md")
    }

    public static func load(applicationSupport: String, fingerprint: String, fs: FileSystem) -> [MarkEntry] {
        let file = path(applicationSupport: applicationSupport, fingerprint: fingerprint)
        guard fs.exists(file), let text = try? fs.readString(file) else { return [] }
        return MarksDocument.parse(text, forcedScope: .local).marks
    }

    public static func save(
        _ marks: [MarkEntry],
        applicationSupport: String,
        fingerprint: String,
        document: String,
        fs: FileSystem
    ) throws {
        let file = path(applicationSupport: applicationSupport, fingerprint: fingerprint)
        let rendered = MarksDocument(
            frontMatter: FrontMatter(kind: "marks", document: document, fingerprint: fingerprint),
            marks: marks
        ).render()
        try fs.createDirectory(Paths.parent(file))
        try fs.writeString(file, rendered)
    }
}

/// One in-memory copy of the global marks, shared by every open book.
public final class GlobalMarkHub {
    public static let shared = GlobalMarkHub()

    public private(set) var marks: [MarkEntry] = []
    public private(set) var loaded = false
    private var observers: [UUID: ([MarkEntry]) -> Void] = [:]

    public init() {}

    public func ensureLoaded(applicationSupport: String, fs: FileSystem) {
        guard !loaded else { return }
        marks = GlobalMarks.load(applicationSupport: applicationSupport, fs: fs)
        loaded = true
    }

    public func observe(_ id: UUID, _ handler: @escaping ([MarkEntry]) -> Void) {
        observers[id] = handler
    }

    public func unobserve(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// Saves and tells every other observer. The caller already has `marks`.
    public func publish(_ marks: [MarkEntry], source: UUID, applicationSupport: String, fs: FileSystem) {
        guard marks != self.marks else { return }
        self.marks = marks
        loaded = true
        try? GlobalMarks.save(marks, applicationSupport: applicationSupport, fs: fs)
        let others = observers.filter { $0.key != source }
        for handler in others.values {
            handler(marks)
        }
    }
}

/// The position to open when a global mark targets a book that is not on screen yet.
public enum MarkOpenQueue {
    private static var pending: [String: ReadingPosition] = [:]

    public static func store(path: String, position: ReadingPosition) {
        pending[path] = position
    }

    public static func take(path: String) -> ReadingPosition? {
        pending.removeValue(forKey: path)
    }
}

public enum GlobalMarks {
    public static func path(applicationSupport: String) -> String {
        Paths.join(applicationSupport, "global-marks.md")
    }

    public static func load(applicationSupport: String, fs: FileSystem) -> [MarkEntry] {
        let file = path(applicationSupport: applicationSupport)
        guard fs.exists(file), let text = try? fs.readString(file) else { return [] }
        return MarksDocument.parse(text, forcedScope: .global).marks
    }

    public static func save(_ marks: [MarkEntry], applicationSupport: String, fs: FileSystem) throws {
        let document = MarksDocument(
            frontMatter: FrontMatter(kind: "marks", document: "global", fingerprint: "global"),
            marks: marks
        )
        try fs.createDirectory(applicationSupport)
        try fs.writeString(path(applicationSupport: applicationSupport), document.render())
    }
}
