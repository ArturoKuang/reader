import AppKit
import ReaderCore
import Security

enum AppPaths {
    static var support: String {
        if let override = ProcessInfo.processInfo.environment["READER_QA_SUPPORT"], !override.isEmpty {
            try? FileManager.default.createDirectory(atPath: override, withIntermediateDirectories: true)
            return override
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static var caches: String {
        if let override = ProcessInfo.processInfo.environment["READER_QA_CACHES"], !override.isEmpty {
            try? FileManager.default.createDirectory(atPath: override, withIntermediateDirectories: true)
            return override
        }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static var settingsFile: String { Paths.join(support, "settings.json") }
    static var indexFile: String { Paths.join(support, "index.json") }
}

enum SettingsStore {
    static let didChangeNotification = Notification.Name("ReaderSettingsDidChange")

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
        if Thread.isMainThread {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
    }

    /// Detects installed AI CLIs (`claude`, `codex`, `gemini`) and fills in missing or stale paths.
    /// If the current default provider is an API provider with no Keychain key (or a missing CLI),
    /// promotes the first available CLI so models work out of the box.
    static func autoConfigureCLIsInBackground() {
        Task.detached(priority: .utility) {
            let detectedClaude = CLILocator.locate("claude")
            let detectedCodex = CLILocator.locate("codex")
            let detectedGemini = CLILocator.locate("gemini")
            await MainActor.run {
                let current = load()
                var updated = current
                let fm = FileManager.default
                if updated.claudeCLIPath.map({ !fm.isExecutableFile(atPath: $0) }) ?? true {
                    updated.claudeCLIPath = detectedClaude
                }
                if updated.codexCLIPath.map({ !fm.isExecutableFile(atPath: $0) }) ?? true {
                    updated.codexCLIPath = detectedCodex
                }
                if updated.geminiCLIPath.map({ !fm.isExecutableFile(atPath: $0) }) ?? true {
                    updated.geminiCLIPath = detectedGemini
                }
                let defaultUsable: Bool
                switch updated.defaultProvider {
                case .openai:
                    defaultUsable = !(KeychainStore.load(account: "openai")?.isEmpty ?? true)
                case .anthropic:
                    defaultUsable = !(KeychainStore.load(account: "anthropic")?.isEmpty ?? true)
                case .claudeCLI:
                    defaultUsable = updated.claudeCLIPath.map { fm.isExecutableFile(atPath: $0) } ?? false
                case .codexCLI:
                    defaultUsable = updated.codexCLIPath.map { fm.isExecutableFile(atPath: $0) } ?? false
                case .geminiCLI:
                    defaultUsable = updated.geminiCLIPath.map { fm.isExecutableFile(atPath: $0) } ?? false
                }
                if !defaultUsable {
                    if let p = updated.claudeCLIPath, fm.isExecutableFile(atPath: p) {
                        updated.defaultProvider = .claudeCLI
                    } else if let p = updated.codexCLIPath, fm.isExecutableFile(atPath: p) {
                        updated.defaultProvider = .codexCLI
                    } else if let p = updated.geminiCLIPath, fm.isExecutableFile(atPath: p) {
                        updated.defaultProvider = .geminiCLI
                    }
                }
                if updated != current {
                    save(updated)
                }
            }
        }
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
        let fm = FileManager.default
        var candidates: [String] = []
        if name == "claude" {
            candidates.append(contentsOf: ClaudeExecutable.searchPaths(home: home))
        }
        candidates.append(contentsOf: [
            home + "/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            home + "/.bun/bin/\(name)",
            home + "/.npm-global/bin/\(name)",
            home + "/.volta/bin/\(name)",
            home + "/.asdf/shims/\(name)",
        ])
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }) {
                candidates.append(nvmRoot + "/\(version)/bin/\(name)")
            }
        }
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return loginCommand(name)
    }

    static func resolvedPath(override: String?, name: String) -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return locate(name)
    }

    static func loginCommand(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardInput = FileHandle.nullDevice
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
    var errorMessage: String? = nil
    var hasDictionaryFallback: Bool = false
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
        rows.append(ShortcutRow(title: "Jump to a mark", keys: "` or ', then the key"))
        rows.append(ShortcutRow(title: "Show marks", keys: "`, then ?"))
        rows.append(ShortcutRow(title: "Split the page", keys: "Ctrl-W, then v"))
        rows.append(ShortcutRow(title: "Close the pane", keys: "Ctrl-W, then q"))
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

