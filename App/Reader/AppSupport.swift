import AppKit
import ReaderCore
import Security

enum AppPaths {
    static var support: String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static var caches: String {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static var settingsFile: String { Paths.join(support, "settings.json") }
    static var indexFile: String { Paths.join(support, "index.json") }
}

enum SettingsStore {
    static func load() -> AISettings {
        let fs = LocalFileSystem()
        guard let data = try? fs.read(AppPaths.settingsFile),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: AISettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? LocalFileSystem().write(AppPaths.settingsFile, data)
    }
}

enum KeychainStore {
    static let service = "com.reader.Reader"

    static func save(account: String, secret: String) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
}

enum CLILocator {
    /// Dock-launched apps do not see a login shell's PATH.
    static func locate(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = name == "claude"
            ? ClaudeExecutable.searchPaths(home: home)
            : [home + "/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return loginCommand(name)
    }

    static func loginCommand(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

enum ReaderColor {
    static func nsColor(_ color: Int) -> NSColor {
        guard let rgb = HighlightPalette.rgb(color) else { return .systemYellow }
        return NSColor(calibratedRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
}

struct SelectionContext: Equatable {
    var text: String
    var page: Int?
    var cfi: String?
    var section: String?
    var prefix: String
    var suffix: String
    var sentence: String
    var rects: [[Double]]
}

struct LookupPresentation: Identifiable, Equatable {
    var id = UUID()
    var word: String
    var partOfSpeech: String
    var definition: String
    var explanation: String
    var sentence: String
    var location: String
    var providerLabel: String
    var undo: WordUndo
    var busy: Bool
}

struct OutlineRow: Identifiable, Equatable {
    var id: String
    var title: String
    var page: Int?
    var cfi: String?
    var depth: Int
}

struct SearchHit: Identifiable, Equatable {
    var id: Int
    var page: Int
    var snippet: String
    var section: String
}

struct ReaderChatLine: Identifiable, Equatable {
    var id: UUID
    var mine: Bool
    var text: String
}

struct ShortcutRow: Identifiable {
    var id: String { title }
    var title: String
    var keys: String
}

enum ShortcutCatalog {
    static let rows: [ShortcutRow] = [
        ShortcutRow(title: "Hide Sidebar", keys: "⌥⌘1"),
        ShortcutRow(title: "Thumbnails", keys: "⌥⌘2"),
        ShortcutRow(title: "Table of Contents", keys: "⌥⌘3"),
        ShortcutRow(title: "Highlights and Notes", keys: "⌥⌘4"),
        ShortcutRow(title: "Bookmarks", keys: "⌥⌘5"),
        ShortcutRow(title: "Contact Sheet", keys: "⌥⌘6"),
        ShortcutRow(title: "Continuous Scroll", keys: "⌘1"),
        ShortcutRow(title: "Single Page", keys: "⌘2"),
        ShortcutRow(title: "Two Pages", keys: "⌘3"),
        ShortcutRow(title: "Actual Size", keys: "⌘0"),
        ShortcutRow(title: "Zoom to Fit", keys: "⌘9"),
        ShortcutRow(title: "Fit Width", keys: "⌘8"),
        ShortcutRow(title: "Zoom In", keys: "⌘+"),
        ShortcutRow(title: "Zoom Out", keys: "⌘−"),
        ShortcutRow(title: "Zoom to Selection", keys: "⌘*"),
        ShortcutRow(title: "Rotate Left", keys: "⌘L"),
        ShortcutRow(title: "Rotate Right", keys: "⌘R"),
        ShortcutRow(title: "Find", keys: "⌘F"),
        ShortcutRow(title: "Find Next", keys: "⌘G"),
        ShortcutRow(title: "Find Previous", keys: "⇧⌘G"),
        ShortcutRow(title: "Go to Page", keys: "⌥⌘G"),
        ShortcutRow(title: "Back / Forward", keys: "⌘[ / ⌘]"),
        ShortcutRow(title: "Bookmark this page", keys: "⌘D"),
        ShortcutRow(title: "Show Inspector", keys: "⌘I"),
        ShortcutRow(title: "Show or hide right panel", keys: "⌥⌘0"),
        ShortcutRow(title: "Enter Full Screen", keys: "⌃⌘F"),
        ShortcutRow(title: "Slideshow", keys: "⇧⌘F"),
        ShortcutRow(title: "Notes / Words / Ask AI", keys: "⌃1 / ⌃2 / ⌃3"),
        ShortcutRow(title: "Ask AI (alternate)", keys: "⌃4"),
        ShortcutRow(title: "Highlight with color 1–6", keys: "⌃⌘1 … ⌃⌘6"),
        ShortcutRow(title: "Highlight with last color", keys: "⌃⌘H"),
        ShortcutRow(title: "Add note to selection", keys: "⇧⌘N or ⌃⌘N"),
        ShortcutRow(title: "Look up selection", keys: "⌃⌘D"),
        ShortcutRow(title: "Ask AI about selection", keys: "⌘K"),
        ShortcutRow(title: "Copy with citation", keys: "⇧⌘C"),
        ShortcutRow(title: "Show notes in the margin", keys: "⌥⌘E"),
        ShortcutRow(title: "Export notes as Markdown", keys: "⇧⌥⌘E"),
        ShortcutRow(title: "Set a vim mark", keys: "m, then a key"),
        ShortcutRow(title: "Jump to a mark", keys: "`, then the key"),
        ShortcutRow(title: "Jump back", keys: "`, then `"),
        ShortcutRow(title: "Words window", keys: "⇧⌘W"),
        ShortcutRow(title: "Export all words", keys: "⇧⌘E"),
        ShortcutRow(title: "Settings", keys: "⌘,"),
    ]
}
