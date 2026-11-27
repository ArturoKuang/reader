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

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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
    static func current() -> [ShortcutRow] {
        var rows: [ShortcutRow] = []
        if let menu = NSApp.mainMenu { walk(menu, into: &rows) }
        rows.append(ShortcutRow(title: "Set a vim mark", keys: "m, then a key"))
        rows.append(ShortcutRow(title: "Jump to a mark", keys: "`, then the key"))
        rows.append(ShortcutRow(title: "Jump back", keys: "`, then `"))
        rows.append(ShortcutRow(title: "Next search hit", keys: "n"))
        rows.append(ShortcutRow(title: "Previous search hit", keys: "N"))
        return rows
    }

    private static func walk(_ menu: NSMenu, into rows: inout [ShortcutRow]) {
        for item in menu.items {
            if let submenu = item.submenu {
                walk(submenu, into: &rows)
                continue
            }
            if item.isSeparatorItem || item.isHidden || item.isAlternate || item.keyEquivalent.isEmpty { continue }
            rows.append(ShortcutRow(title: item.title, keys: format(item)))
        }
    }

    private static func format(_ item: NSMenuItem) -> String {
        var prefix = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { prefix += "⌃" }
        if mask.contains(.option) { prefix += "⌥" }
        if mask.contains(.shift) { prefix += "⇧" }
        if mask.contains(.command) { prefix += "⌘" }
        let key = item.keyEquivalent
        if key == String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!) { return prefix + "↓" }
        if key == String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!) { return prefix + "↑" }
        if key == String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!) { return prefix + "←" }
        if key == String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!) { return prefix + "→" }
        return prefix + key.uppercased()
    }
}

/// Find's search field action also fires when the field resigns first responder.
/// Only Return/Enter should advance to the next match.
enum FindCommit {
    static func isExplicitAdvance(_ event: NSEvent? = NSApp.currentEvent) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .keyDown, .keyUp:
            return event.keyCode == 36 || event.keyCode == 76
        default:
            return false
        }
    }
}

