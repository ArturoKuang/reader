import Foundation

public struct VaultLocation: Equatable, Sendable {
    public var vaultRoot: String
    public var vaultName: String
    public var bookFolder: String

    public init(vaultRoot: String, vaultName: String, bookFolder: String) {
        self.vaultRoot = vaultRoot
        self.vaultName = vaultName
        self.bookFolder = bookFolder
    }
}

public enum VaultFinder {
    /// Walks up from the book file's parent until a directory contains `.obsidian`.
    /// The book folder is that parent, not the vault root.
    public static func locate(bookPath: String, fs: FileSystem) -> VaultLocation? {
        var directory = Paths.parent(bookPath)
        if directory == "." || directory.isEmpty { return nil }
        var guardrail = 0
        while directory != "/" && guardrail < 40 {
            guardrail += 1
            let marker = Paths.join(directory, ".obsidian")
            if fs.isDirectory(marker) {
                return VaultLocation(vaultRoot: directory, vaultName: Paths.name(directory), bookFolder: Paths.parent(bookPath))
            }
            let parent = Paths.parent(directory)
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    public enum Kind: Equatable, Sendable {
        case bookFolder
        case loose
    }

    /// A book folder already has notes, a curriculum, or a tutor file. A loose file only happens to sit in the vault.
    public static func classify(bookFolder: String, fs: FileSystem) -> Kind {
        if fs.exists(Paths.join(bookFolder, "CLAUDE.md")) { return .bookFolder }
        if fs.isDirectory(Paths.join(bookFolder, "curriculum")) { return .bookFolder }
        if fs.isDirectory(Paths.join(bookFolder, "notes")) { return .bookFolder }
        return .loose
    }

    public enum Open: Equatable, Sendable {
        case vault(VaultLocation)
        case missingLink(String)
        case none
    }

    /// An explicit link wins. A missing linked folder does not fall through to a parent vault.
    public static func resolve(bookPath: String, linkedFolder: String?, fs: FileSystem) -> Open {
        if let linkedFolder {
            guard fs.isDirectory(linkedFolder) else { return .missingLink(linkedFolder) }
            let probe = Paths.join(linkedFolder, "book.pdf")
            guard let found = locate(bookPath: probe, fs: fs) else { return .missingLink(linkedFolder) }
            return .vault(VaultLocation(vaultRoot: found.vaultRoot, vaultName: found.vaultName, bookFolder: linkedFolder))
        }
        guard let found = locate(bookPath: bookPath, fs: fs) else { return .none }
        return .vault(found)
    }
}

public enum ChapterFiles {
    public static func number(in heading: String) -> Int? {
        let lowered = heading.lowercased()
        let markers = ["chapter ", "ch. ", "ch "]
        for marker in markers {
            guard let range = lowered.range(of: marker) else { continue }
            let rest = lowered[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let value = Int(digits), !digits.isEmpty { return value }
        }
        let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "introduction" || trimmed.hasPrefix("introduction ") || trimmed.hasPrefix("introduction:") || trimmed == "intro" || trimmed.hasPrefix("preface") {
            return 0
        }
        return nil
    }

    public static func notesFile(chapter: Int?, bookTitle: String) -> String {
        if let chapter {
            return "Chapter \(chapter).md"
        }
        let trimmed = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Notes" : trimmed
        return title.hasSuffix(".md") ? title : title + ".md"
    }

    /// `book/00-introduction.md` or the first `book/NN*.md` for that chapter.
    public static func chapterTextFile(bookFolder: String, chapter: Int, fs: FileSystem) -> String? {
        let directory = Paths.join(bookFolder, "book")
        guard let names = try? fs.list(directory) else { return nil }
        if chapter == 0 {
            return names.first { $0.hasPrefix("00") }.map { Paths.join("book", $0) }
        }
        let prefix = String(format: "%02d", chapter)
        return names.first { $0.hasPrefix(prefix) }.map { Paths.join("book", $0) }
    }
}

public struct VaultBookSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var notesFolder: String
    public var vocabularyFile: String?
    public var claudeSessionID: String?
    public var showConceptMarkers: Bool
    public var view: ViewState
    public var marksMarkdown: String

    public init(
        enabled: Bool = true,
        notesFolder: String = "notes",
        vocabularyFile: String? = nil,
        claudeSessionID: String? = nil,
        showConceptMarkers: Bool = true,
        view: ViewState = .fresh,
        marksMarkdown: String = ""
    ) {
        self.enabled = enabled
        self.notesFolder = notesFolder
        self.vocabularyFile = vocabularyFile
        self.claudeSessionID = claudeSessionID
        self.showConceptMarkers = showConceptMarkers
        self.view = view
        self.marksMarkdown = marksMarkdown
    }

    public static func load(bookFolder: String, fs: FileSystem) -> VaultBookSettings {
        let path = Paths.join(bookFolder, ".reader-state.json")
        guard let data = try? fs.read(path),
              let settings = try? JSONDecoder().decode(VaultBookSettings.self, from: data) else {
            return VaultBookSettings()
        }
        return settings
    }

    public func save(bookFolder: String, fs: FileSystem) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.write(Paths.join(bookFolder, ".reader-state.json"), try encoder.encode(self))
    }
}

public enum VaultPaths {
    public static func notesDirectory(bookFolder: String, settings: VaultBookSettings) -> String {
        Paths.join(bookFolder, settings.notesFolder)
    }

    public static func vocabularyFile(bookFolder: String, settings: VaultBookSettings, fs: FileSystem) -> String {
        if let custom = settings.vocabularyFile, !custom.isEmpty {
            return custom.hasPrefix("/") ? custom : Paths.join(bookFolder, custom)
        }
        let learner = Paths.join(bookFolder, "learner/vocabulary.md")
        if fs.exists(learner) { return learner }
        return Paths.join(bookFolder, "words.md")
    }
}
