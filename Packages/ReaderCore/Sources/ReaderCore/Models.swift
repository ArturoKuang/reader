import Foundation

public enum HighlightPalette {
    public static let count = 6
    /// Unnamed swatches. Files store colors as 1...6. The hues match the design draft
    /// so a highlight is recognizable; the UI labels them only by number.
    public static let hex = ["F2C94C", "6FCF97", "56CCF2", "F28FB1", "BB6BD9", "F2994A"]

    public static func isValid(_ color: Int) -> Bool {
        (1...count).contains(color)
    }

    public static func rgb(_ color: Int) -> (r: Double, g: Double, b: Double)? {
        guard isValid(color) else { return nil }
        let hex = hex[color - 1]
        guard let value = Int(hex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xff) / 255,
            Double((value >> 8) & 0xff) / 255,
            Double(value & 0xff) / 255
        )
    }
}

public enum SidebarMode: String, Codable, Equatable, Sendable, CaseIterable {
    case hidden
    case thumbnails
    case tableOfContents
    case highlightsAndNotes
    case bookmarks
    case contactSheet
    case searchResults
}

public enum PanelTab: String, Codable, Equatable, Sendable, CaseIterable {
    case notes
    case words
    case highlights
    case askAI
}

public enum FitMode: String, Codable, Equatable, Sendable {
    case actual
    case fitWidth
    case fitPage
    case custom
}

public struct Bookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var page: Int?
    public var cfi: String?
    public var title: String
    public var section: String?

    public init(id: String, page: Int? = nil, cfi: String? = nil, title: String, section: String? = nil) {
        self.id = id
        self.page = page
        self.cfi = cfi
        self.title = title
        self.section = section
    }
}

public struct StoredWindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ViewState: Codable, Equatable, Sendable {
    public var version: Int
    public var page: Int
    public var scrollY: Double?
    public var zoom: Double
    public var fitMode: FitMode
    /// Preview treats continuous scroll and single/two-page as independent checks.
    public var continuous: Bool
    public var twoPages: Bool
    public var sidebar: SidebarMode
    public var panelVisible: Bool
    public var panelTab: PanelTab
    /// Page number (string key) to clockwise degrees. Applied in memory; the book file is not rewritten.
    public var rotations: [String: Int]
    public var bookmarks: [Bookmark]
    public var lastHighlightColor: Int
    /// Window frame in screen points. Older sidecars omit this.
    public var windowFrame: StoredWindowFrame?
    /// When true, notes draw as margin cards if the page has room. Older sidecars omit this.
    public var showMarginNotes: Bool
    public var epubTheme: String
    public var epubFont: String
    public var epubLine: Int
    public var epubMargin: Int
    public var epubJustify: Bool
    /// A book outside the vault can point at a book folder. Older sidecars omit this.
    public var vaultBookFolder: String?

    public init(
        version: Int = 1,
        page: Int = 1,
        scrollY: Double? = nil,
        zoom: Double = 1,
        fitMode: FitMode = .fitPage,
        continuous: Bool = true,
        twoPages: Bool = false,
        sidebar: SidebarMode = .thumbnails,
        panelVisible: Bool = true,
        panelTab: PanelTab = .notes,
        rotations: [String: Int] = [:],
        bookmarks: [Bookmark] = [],
        lastHighlightColor: Int = 1,
        windowFrame: StoredWindowFrame? = nil,
        showMarginNotes: Bool = false,
        epubTheme: String = "original",
        epubFont: String = "Original",
        epubLine: Int = 1,
        epubMargin: Int = 1,
        epubJustify: Bool = false,
        vaultBookFolder: String? = nil
    ) {
        self.version = version
        self.page = page
        self.scrollY = scrollY
        self.zoom = zoom
        self.fitMode = fitMode
        self.continuous = continuous
        self.twoPages = twoPages
        self.sidebar = sidebar
        self.panelVisible = panelVisible
        self.panelTab = panelTab
        self.rotations = rotations
        self.bookmarks = bookmarks
        self.lastHighlightColor = lastHighlightColor
        self.windowFrame = windowFrame
        self.showMarginNotes = showMarginNotes
        self.epubTheme = epubTheme
        self.epubFont = epubFont
        self.epubLine = epubLine
        self.epubMargin = epubMargin
        self.epubJustify = epubJustify
        self.vaultBookFolder = vaultBookFolder
    }

    public static var fresh: ViewState { ViewState() }

    private enum CodingKeys: String, CodingKey {
        case version, page, scrollY, zoom, fitMode, continuous, twoPages
        case sidebar, panelVisible, panelTab, rotations, bookmarks, lastHighlightColor, windowFrame, showMarginNotes
        case epubTheme, epubFont, epubLine, epubMargin, epubJustify, vaultBookFolder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        scrollY = try container.decodeIfPresent(Double.self, forKey: .scrollY)
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        fitMode = try container.decodeIfPresent(FitMode.self, forKey: .fitMode) ?? .fitPage
        continuous = try container.decodeIfPresent(Bool.self, forKey: .continuous) ?? true
        twoPages = try container.decodeIfPresent(Bool.self, forKey: .twoPages) ?? false
        sidebar = try container.decodeIfPresent(SidebarMode.self, forKey: .sidebar) ?? .thumbnails
        panelVisible = try container.decodeIfPresent(Bool.self, forKey: .panelVisible) ?? true
        panelTab = try container.decodeIfPresent(PanelTab.self, forKey: .panelTab) ?? .notes
        rotations = try container.decodeIfPresent([String: Int].self, forKey: .rotations) ?? [:]
        bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        lastHighlightColor = try container.decodeIfPresent(Int.self, forKey: .lastHighlightColor) ?? 1
        windowFrame = try container.decodeIfPresent(StoredWindowFrame.self, forKey: .windowFrame)
        showMarginNotes = try container.decodeIfPresent(Bool.self, forKey: .showMarginNotes) ?? false
        epubTheme = try container.decodeIfPresent(String.self, forKey: .epubTheme) ?? "original"
        epubFont = try container.decodeIfPresent(String.self, forKey: .epubFont) ?? "Original"
        epubLine = try container.decodeIfPresent(Int.self, forKey: .epubLine) ?? 1
        epubMargin = try container.decodeIfPresent(Int.self, forKey: .epubMargin) ?? 1
        epubJustify = try container.decodeIfPresent(Bool.self, forKey: .epubJustify) ?? false
        vaultBookFolder = try container.decodeIfPresent(String.self, forKey: .vaultBookFolder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(page, forKey: .page)
        try container.encodeIfPresent(scrollY, forKey: .scrollY)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(fitMode, forKey: .fitMode)
        try container.encode(continuous, forKey: .continuous)
        try container.encode(twoPages, forKey: .twoPages)
        try container.encode(sidebar, forKey: .sidebar)
        try container.encode(panelVisible, forKey: .panelVisible)
        try container.encode(panelTab, forKey: .panelTab)
        try container.encode(rotations, forKey: .rotations)
        try container.encode(bookmarks, forKey: .bookmarks)
        try container.encode(lastHighlightColor, forKey: .lastHighlightColor)
        try container.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try container.encode(showMarginNotes, forKey: .showMarginNotes)
        try container.encode(epubTheme, forKey: .epubTheme)
        try container.encode(epubFont, forKey: .epubFont)
        try container.encode(epubLine, forKey: .epubLine)
        try container.encode(epubMargin, forKey: .epubMargin)
        try container.encode(epubJustify, forKey: .epubJustify)
        try container.encodeIfPresent(vaultBookFolder, forKey: .vaultBookFolder)
    }
}

/// Exact reading position. `scrollY` is the fraction of the page from the top of the
/// page to the top of the viewport (0 = top). `pdfX`/`pdfY` are PDF user space
/// (origin bottom-left) of that viewport corner when known. EPUB uses `cfi`.
public struct ReadingPosition: Equatable, Sendable {
    public var page: Int?
    public var scrollY: Double?
    public var zoom: Double?
    public var pdfX: Double?
    public var pdfY: Double?
    public var cfi: String?
    public var section: String?
    public var quote: String?
    public var prefix: String?
    public var suffix: String?

    public init(
        page: Int? = nil,
        scrollY: Double? = nil,
        zoom: Double? = nil,
        pdfX: Double? = nil,
        pdfY: Double? = nil,
        cfi: String? = nil,
        section: String? = nil,
        quote: String? = nil,
        prefix: String? = nil,
        suffix: String? = nil
    ) {
        self.page = page
        self.scrollY = scrollY
        self.zoom = zoom
        self.pdfX = pdfX
        self.pdfY = pdfY
        self.cfi = cfi
        self.section = section
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct FrontMatter: Equatable, Sendable {
    public var kind: String
    public var version: Int
    public var document: String
    public var fingerprint: String
    public var pdfID: String?
    public var epubID: String?

    public init(kind: String, version: Int = 1, document: String, fingerprint: String, pdfID: String? = nil, epubID: String? = nil) {
        self.kind = kind
        self.version = version
        self.document = document
        self.fingerprint = fingerprint
        self.pdfID = pdfID
        self.epubID = epubID
    }

    public func withKind(_ kind: String) -> FrontMatter {
        var copy = self
        copy.kind = kind
        return copy
    }

    public var displayTitle: String {
        let file = Paths.stem(document)
        return file.isEmpty ? document : file
    }
}

public struct NoteEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var page: Int?
    public var cfi: String?
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var section: String?
    public var created: String?
    public var updated: String?
    public var ai: Bool
    public var provider: String?
    public var scope: String
    public var body: String
    public var extras: [String: JSONValue]

    public init(
        id: String,
        page: Int? = nil,
        cfi: String? = nil,
        quote: String,
        prefix: String = "",
        suffix: String = "",
        section: String? = nil,
        created: String? = nil,
        updated: String? = nil,
        ai: Bool = false,
        provider: String? = nil,
        scope: String = "passage",
        body: String,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.page = page
        self.cfi = cfi
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.section = section
        self.created = created
        self.updated = updated
        self.ai = ai
        self.provider = provider
        self.scope = scope
        self.body = body
        self.extras = extras
    }
}

public struct HighlightEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var color: Int
    public var page: Int?
    public var cfi: String?
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var section: String?
    public var rects: [[Double]]
    public var noteID: String?
    public var extras: [String: JSONValue]

    public init(
        id: String,
        color: Int,
        page: Int? = nil,
        cfi: String? = nil,
        quote: String,
        prefix: String = "",
        suffix: String = "",
        section: String? = nil,
        rects: [[Double]] = [],
        noteID: String? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.color = color
        self.page = page
        self.cfi = cfi
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.section = section
        self.rects = rects
        self.noteID = noteID
        self.extras = extras
    }
}

public struct LookupEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var page: Int?
    public var cfi: String?
    public var section: String?
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var sentence: String
    public var date: String
    public var extras: [String: JSONValue]

    public init(
        id: String,
        page: Int? = nil,
        cfi: String? = nil,
        section: String? = nil,
        quote: String,
        prefix: String = "",
        suffix: String = "",
        sentence: String,
        date: String,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.page = page
        self.cfi = cfi
        self.section = section
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.sentence = sentence
        self.date = date
        self.extras = extras
    }
}

public struct WordEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var word: String
    public var definition: String
    public var explanation: String?
    public var explanationProvider: String?
    public var pronunciation: String?
    public var partOfSpeech: String?
    public var learned: Bool
    public var lookups: [LookupEntry]
    public var extras: [String: JSONValue]

    public var count: Int { lookups.count }

    public init(
        id: String,
        word: String,
        definition: String,
        explanation: String? = nil,
        explanationProvider: String? = nil,
        pronunciation: String? = nil,
        partOfSpeech: String? = nil,
        learned: Bool = false,
        lookups: [LookupEntry] = [],
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.word = word
        self.definition = definition
        self.explanation = explanation
        self.explanationProvider = explanationProvider
        self.pronunciation = pronunciation
        self.partOfSpeech = partOfSpeech
        self.learned = learned
        self.lookups = lookups
        self.extras = extras
    }
}

public enum MarkScope: String, Equatable, Sendable {
    case local
    case global

    /// Uppercase letters are global across books (vim file marks). Everything else
    /// that can be a mark — lowercase, digits, punctuation — stays in the book.
    public static func forSymbol(_ symbol: String) -> MarkScope {
        guard symbol.count == 1, let character = symbol.first else { return .local }
        if character.isLetter && character.isUppercase { return .global }
        return .local
    }
}

public struct MarkEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var symbol: String
    public var scope: MarkScope
    public var position: ReadingPosition
    public var bookFingerprint: String?
    public var bookPath: String?
    public var documentTitle: String?
    public var setAt: String

    public init(
        id: String,
        symbol: String,
        scope: MarkScope? = nil,
        position: ReadingPosition,
        bookFingerprint: String? = nil,
        bookPath: String? = nil,
        documentTitle: String? = nil,
        setAt: String
    ) {
        self.id = id
        self.symbol = symbol
        self.scope = scope ?? MarkScope.forSymbol(symbol)
        self.position = position
        self.bookFingerprint = bookFingerprint
        self.bookPath = bookPath
        self.documentTitle = documentTitle
        self.setAt = setAt
    }
}

public enum ProviderID: String, Codable, Equatable, Sendable, CaseIterable {
    case openai
    case anthropic
    case claudeCLI
    case codexCLI

    public var label: String {
        switch self {
        case .openai: return "ChatGPT"
        case .anthropic: return "Claude"
        case .claudeCLI: return "Claude Code"
        case .codexCLI: return "Codex"
        }
    }

    public var isCLI: Bool {
        self == .claudeCLI || self == .codexCLI
    }
}

public struct AISettings: Codable, Equatable, Sendable {
    public var defaultProvider: ProviderID
    public var openAIModel: String
    public var anthropicModel: String
    public var openAIContextTokens: Int
    public var anthropicContextTokens: Int
    public var claudeCLIPath: String?
    public var codexCLIPath: String?
    public var lookupUsesDefault: Bool
    public var lookupProvider: ProviderID
    /// Suggested notes stay off until the reader turns them on.
    public var suggestedNotes: Bool
    /// The small bar above a text selection. Preview-style reading can turn it off.
    public var showSelectionBar: Bool
    /// Read-aloud speed; 1.0 is the normal speaking rate.
    public var ttsRateMultiplier: Double
    /// nil uses the system voice.
    public var ttsVoiceIdentifier: String?

    public init(
        defaultProvider: ProviderID = .openai,
        openAIModel: String = "gpt-4.1",
        anthropicModel: String = "claude-sonnet-4-5",
        openAIContextTokens: Int = 1_047_576,
        anthropicContextTokens: Int = 200_000,
        claudeCLIPath: String? = nil,
        codexCLIPath: String? = nil,
        lookupUsesDefault: Bool = true,
        lookupProvider: ProviderID = .openai,
        suggestedNotes: Bool = false,
        showSelectionBar: Bool = true,
        ttsRateMultiplier: Double = 1.0,
        ttsVoiceIdentifier: String? = nil
    ) {
        self.defaultProvider = defaultProvider
        self.openAIModel = openAIModel
        self.anthropicModel = anthropicModel
        self.openAIContextTokens = openAIContextTokens
        self.anthropicContextTokens = anthropicContextTokens
        self.claudeCLIPath = claudeCLIPath
        self.codexCLIPath = codexCLIPath
        self.lookupUsesDefault = lookupUsesDefault
        self.lookupProvider = lookupProvider
        self.suggestedNotes = suggestedNotes
        self.showSelectionBar = showSelectionBar
        self.ttsRateMultiplier = ttsRateMultiplier
        self.ttsVoiceIdentifier = ttsVoiceIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case defaultProvider, openAIModel, anthropicModel, openAIContextTokens, anthropicContextTokens
        case claudeCLIPath, codexCLIPath, lookupUsesDefault, lookupProvider, suggestedNotes, showSelectionBar
        case ttsRateMultiplier, ttsVoiceIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultProvider = try container.decodeIfPresent(ProviderID.self, forKey: .defaultProvider) ?? .openai
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-4.1"
        anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel) ?? "claude-sonnet-4-5"
        openAIContextTokens = try container.decodeIfPresent(Int.self, forKey: .openAIContextTokens) ?? 1_047_576
        anthropicContextTokens = try container.decodeIfPresent(Int.self, forKey: .anthropicContextTokens) ?? 200_000
        claudeCLIPath = try container.decodeIfPresent(String.self, forKey: .claudeCLIPath)
        codexCLIPath = try container.decodeIfPresent(String.self, forKey: .codexCLIPath)
        lookupUsesDefault = try container.decodeIfPresent(Bool.self, forKey: .lookupUsesDefault) ?? true
        lookupProvider = try container.decodeIfPresent(ProviderID.self, forKey: .lookupProvider) ?? .openai
        suggestedNotes = try container.decodeIfPresent(Bool.self, forKey: .suggestedNotes) ?? false
        showSelectionBar = try container.decodeIfPresent(Bool.self, forKey: .showSelectionBar) ?? true
        ttsRateMultiplier = try container.decodeIfPresent(Double.self, forKey: .ttsRateMultiplier) ?? 1.0
        ttsVoiceIdentifier = try container.decodeIfPresent(String.self, forKey: .ttsVoiceIdentifier)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultProvider, forKey: .defaultProvider)
        try container.encode(openAIModel, forKey: .openAIModel)
        try container.encode(anthropicModel, forKey: .anthropicModel)
        try container.encode(openAIContextTokens, forKey: .openAIContextTokens)
        try container.encode(anthropicContextTokens, forKey: .anthropicContextTokens)
        try container.encodeIfPresent(claudeCLIPath, forKey: .claudeCLIPath)
        try container.encodeIfPresent(codexCLIPath, forKey: .codexCLIPath)
        try container.encode(lookupUsesDefault, forKey: .lookupUsesDefault)
        try container.encode(lookupProvider, forKey: .lookupProvider)
        try container.encode(suggestedNotes, forKey: .suggestedNotes)
        try container.encode(showSelectionBar, forKey: .showSelectionBar)
        try container.encode(ttsRateMultiplier, forKey: .ttsRateMultiplier)
        try container.encodeIfPresent(ttsVoiceIdentifier, forKey: .ttsVoiceIdentifier)
    }

    public static let `default` = AISettings()

    public func contextTokens(for provider: ProviderID) -> Int {
        switch provider {
        case .openai: return openAIContextTokens
        case .anthropic: return anthropicContextTokens
        case .claudeCLI, .codexCLI: return Int.max
        }
    }

    public func model(for provider: ProviderID) -> String? {
        switch provider {
        case .openai: return openAIModel
        case .anthropic: return anthropicModel
        case .claudeCLI, .codexCLI: return nil
        }
    }
}
