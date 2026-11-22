import AppKit
import ReaderCore
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?
    private var settingsWindow: NSWindow?
    private var wordsWindow: NSWindow?
    private var shortcutsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSDocumentController.shared.documents.isEmpty {
            showWelcome(nil)
        }
        if !FileManager.default.fileExists(atPath: AppPaths.settingsFile) {
            Task.detached {
                guard CLILocator.locate("claude") != nil else { return }
                await MainActor.run {
                    var settings = SettingsStore.load()
                    settings.defaultProvider = .claudeCLI
                    SettingsStore.save(settings)
                }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "reader" {
            guard let link = ReaderLink.parse(url.absoluteString) else { continue }
            let book = URL(fileURLWithPath: link.path)
            NSDocumentController.shared.openDocument(withContentsOf: book, display: true) { document, _, _ in
                (document as? ReaderDocument)?.reveal(link)
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            let host = NSHostingController(rootView: WelcomeView())
            let window = NSWindow(contentViewController: host)
            window.title = "Reader"
            window.setContentSize(NSSize(width: 520, height: 420))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            welcome = window
        }
        welcome?.center()
        welcome?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDocument(_ sender: Any?) {
        NSDocumentController.shared.openDocument(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Reader Settings"
            window.setContentSize(NSSize(width: 560, height: 640))
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.setContentSize(NSSize(width: 500, height: 560))
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showWords(_ sender: Any?) {
        let books = LibraryIndex.load(from: AppPaths.indexFile, fs: LocalFileSystem()).documents
        let host = NSHostingController(rootView: WordsBrowser(books: books))
        let window = NSWindow(contentViewController: host)
        window.title = "Words"
        window.setContentSize(NSSize(width: 860, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        wordsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil {
            let host = NSHostingController(rootView: ShortcutsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Keyboard Shortcuts"
            window.setContentSize(NSSize(width: 520, height: 640))
            window.styleMask = [.titled, .closable, .resizable]
            shortcutsWindow = window
        }
        shortcutsWindow?.center()
        shortcutsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func exportAllWords(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "All words.md"
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let csv = url.pathExtension.lowercased() == "csv"
            let (text, missing) = WordLibrary.export(csv: csv)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                if !missing.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some books were skipped"
                    alert.informativeText = missing.joined(separator: "\n")
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't export words"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        main.addItem(menu("Reader", items: [
            item("About Reader", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            separator(),
            item("Settings…", #selector(showSettings(_:)), ",", .command),
            separator(),
            item("Hide Reader", #selector(NSApplication.hide(_:)), "h", .command),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            separator(),
            item("Quit Reader", #selector(NSApplication.terminate(_:)), "q", .command),
        ]))
        main.addItem(menu("File", items: [
            item("Open…", #selector(openDocument(_:)), "o", .command),
            item("Open in Other Pane…", #selector(ReaderWindowController.openInOtherPane(_:))),
            item("Link to Vault Book Folder…", #selector(ReaderWindowController.linkVaultFolder(_:))),
            separator(),
            item("Export All Words…", #selector(exportAllWords(_:)), "e", [.command, .shift]),
            item("Export Notes as Markdown…", #selector(ReaderWindowController.exportNotes(_:)), "e", [.command, .shift, .option]),
            separator(),
            item("Close", #selector(ReaderWindowController.closePaneOrWindow(_:)), "w", .command),
            item("Save", #selector(NSDocument.save(_:)), "s", .command),
        ]))
        // Recent menu: the line above is awkward if submenu returns nil. Fix below after construction.
        main.addItem(menu("Edit", items: [
            item("Undo", Selector(("undo:")), "z", .command),
            item("Redo", Selector(("redo:")), "Z", .command),
            separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", .command),
            item("Copy", #selector(NSText.copy(_:)), "c", .command),
            item("Copy with Citation", #selector(ReaderWindowController.copyCitation(_:)), "c", [.command, .shift]),
            item("Copy All Notes as Markdown", #selector(ReaderWindowController.copyAllNotes(_:))),
            item("Paste", #selector(NSText.paste(_:)), "v", .command),
            item("Select All", #selector(ReaderWindowController.selectAll(_:)), "a", .command),
            item("Delete", #selector(ReaderWindowController.delete(_:)), "\u{8}", .command),
            separator(),
            item("Find…", #selector(ReaderWindowController.find(_:)), "f", .command),
            item("Find Next", #selector(ReaderWindowController.findNext(_:)), "g", .command),
            item("Find Previous", #selector(ReaderWindowController.findPrevious(_:)), "g", [.command, .shift]),
        ]))
        main.addItem(menu("View", items: [
            item("Hide Sidebar", #selector(ReaderWindowController.hideSidebar(_:)), "1", [.command, .option]),
            item("Thumbnails", #selector(ReaderWindowController.showThumbnails(_:)), "2", [.command, .option]),
            item("Table of Contents", #selector(ReaderWindowController.showContents(_:)), "3", [.command, .option]),
            item("Highlights and Notes", #selector(ReaderWindowController.showHighlightsAndNotes(_:)), "4", [.command, .option]),
            item("Bookmarks", #selector(ReaderWindowController.showBookmarks(_:)), "5", [.command, .option]),
            item("Contact Sheet", #selector(ReaderWindowController.showContactSheet(_:)), "6", [.command, .option]),
            separator(),
            item("Continuous Scroll", #selector(ReaderWindowController.toggleContinuous(_:)), "1", .command),
            item("Single Page", #selector(ReaderWindowController.singlePage(_:)), "2", .command),
            item("Two Pages", #selector(ReaderWindowController.twoPages(_:)), "3", .command),
            separator(),
            item("Actual Size", #selector(ReaderWindowController.actualSize(_:)), "0", .command),
            item("Zoom to Fit", #selector(ReaderWindowController.zoomToFit(_:)), "9", .command),
            item("Fit Width", #selector(ReaderWindowController.fitWidth(_:)), "8", .command),
            item("Zoom In", #selector(ReaderWindowController.zoomIn(_:)), "+", .command),
            item("Zoom Out", #selector(ReaderWindowController.zoomOut(_:)), "-", .command),
            item("Zoom to Selection", #selector(ReaderWindowController.zoomToSelection(_:)), "*", .command),
            separator(),
            item("Split Side by Side", #selector(ReaderWindowController.splitSideBySide(_:)), "\\", .command),
            item("Split Stacked", #selector(ReaderWindowController.splitStacked(_:))),
            item("Focus Next Pane", #selector(ReaderWindowController.focusNextPane(_:)), "\t", .control),
            item("Focus Previous Pane", #selector(ReaderWindowController.focusPreviousPane(_:)), "\t", [.control, .shift]),
            separator(),
            item("Rotate Left", #selector(ReaderWindowController.rotateLeft(_:)), "l", .command),
            item("Rotate Right", #selector(ReaderWindowController.rotateRight(_:)), "r", .command),
            separator(),
            item("Show Inspector", #selector(ReaderWindowController.togglePanel(_:)), "i", .command),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            item("Slideshow", #selector(ReaderWindowController.slideshow(_:)), "f", [.command, .shift]),
            separator(),
            item("Notes", #selector(ReaderWindowController.showNotesTab(_:)), "1", .control),
            item("Words", #selector(ReaderWindowController.showWordsTab(_:)), "2", .control),
            item("Ask AI", #selector(ReaderWindowController.showAskTab(_:)), "3", .control),
            item("Ask AI", #selector(ReaderWindowController.showAskTab(_:)), "4", .control),
            item("Show Notes in Margin", #selector(ReaderWindowController.showMarginNotes(_:)), "e", [.command, .option]),
        ]))
        main.addItem(menu("Go", items: [
            item("Back", #selector(ReaderWindowController.goBack(_:)), "[", .command),
            item("Forward", #selector(ReaderWindowController.goForward(_:)), "]", .command),
            separator(),
            item("Go to Page…", #selector(ReaderWindowController.goToPage(_:)), "g", [.command, .option]),
            item("Next Page", #selector(ReaderWindowController.nextPage(_:)), Self.arrow(Int(NSDownArrowFunctionKey)), [.command, .option]),
            item("Previous Page", #selector(ReaderWindowController.previousPage(_:)), Self.arrow(Int(NSUpArrowFunctionKey)), [.command, .option]),
            item("Next Chapter", #selector(ReaderWindowController.nextChapter(_:)), Self.arrow(Int(NSRightArrowFunctionKey)), [.command, .option]),
            item("Previous Chapter", #selector(ReaderWindowController.previousChapter(_:)), Self.arrow(Int(NSLeftArrowFunctionKey)), [.command, .option]),
        ]))
        main.addItem(menu("Tools", items: [
            item("Highlight Yellow", #selector(ReaderWindowController.highlight1(_:)), "1", [.command, .control]),
            item("Highlight Green", #selector(ReaderWindowController.highlight2(_:)), "2", [.command, .control]),
            item("Highlight Blue", #selector(ReaderWindowController.highlight3(_:)), "3", [.command, .control]),
            item("Highlight Pink", #selector(ReaderWindowController.highlight4(_:)), "4", [.command, .control]),
            item("Highlight Purple", #selector(ReaderWindowController.highlight5(_:)), "5", [.command, .control]),
            item("Highlight Orange", #selector(ReaderWindowController.highlight6(_:)), "6", [.command, .control]),
            item("Highlight with Last Color", #selector(ReaderWindowController.highlightLast(_:)), "h", [.command, .control]),
            separator(),
            item("Add Note", #selector(ReaderWindowController.addNote(_:)), "n", [.command, .shift]),
            item("Add Note", #selector(ReaderWindowController.addNote(_:)), "n", [.command, .control]),
            item("Look Up", #selector(ReaderWindowController.lookUp(_:)), "d", [.command, .control]),
            item("Ask AI…", #selector(ReaderWindowController.askAI(_:)), "k", .command),
            item("Explain Simply", #selector(ReaderWindowController.explainSimply(_:))),
            item("Summarize Section", #selector(ReaderWindowController.summarizeSection(_:))),
            separator(),
            item("Bookmark This Page", #selector(ReaderWindowController.bookmarkPage(_:)), "d", .command),
            item("Reveal in Obsidian", #selector(ReaderWindowController.revealInObsidian(_:))),
            item("Open Vault Folder", #selector(ReaderWindowController.openVaultFolder(_:))),
            item("Pause Saving to Vault", #selector(ReaderWindowController.pauseVault(_:))),
            item("Vault Settings", #selector(showSettings(_:))),
            item("Concept Markers", #selector(ReaderWindowController.toggleConceptMarkers(_:))),
            item("Words", #selector(showWords(_:)), "w", [.command, .shift]),
        ]))
        main.addItem(menu("Window", items: [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
            separator(),
            item("Welcome to Reader", #selector(showWelcome(_:)), "1", [.command, .shift]),
        ]))
        main.addItem(menu("Help", items: [
            item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "?", .command),
        ]))
        if let view = main.item(withTitle: "View")?.submenu {
            let appearance = NSMenu(title: "Appearance")
            for title in ["Original", "Paper", "Quiet", "Night"] {
                let theme = item(title, #selector(ReaderWindowController.chooseTheme(_:)))
                appearance.addItem(theme)
            }
            appearance.addItem(.separator())
            for title in ["Original", "New York", "San Francisco", "Georgia", "Charter", "Iowan"] {
                appearance.addItem(item(title, #selector(ReaderWindowController.chooseFont(_:))))
            }
            appearance.addItem(.separator())
            appearance.addItem(tagged("Tight", #selector(ReaderWindowController.chooseLineSpacing(_:)), 0))
            appearance.addItem(tagged("Comfortable", #selector(ReaderWindowController.chooseLineSpacing(_:)), 1))
            appearance.addItem(tagged("Loose", #selector(ReaderWindowController.chooseLineSpacing(_:)), 2))
            appearance.addItem(.separator())
            appearance.addItem(tagged("Narrow Margins", #selector(ReaderWindowController.chooseMargin(_:)), 0))
            appearance.addItem(tagged("Normal Margins", #selector(ReaderWindowController.chooseMargin(_:)), 1))
            appearance.addItem(tagged("Wide Margins", #selector(ReaderWindowController.chooseMargin(_:)), 2))
            appearance.addItem(item("Justify", #selector(ReaderWindowController.chooseJustify(_:))))
            let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
            appearanceItem.submenu = appearance
            view.addItem(appearanceItem)
        }
        hideShortcutAlias(in: main.item(withTitle: "View")?.submenu, title: "Ask AI", key: "4")
        hideShortcutAlias(in: main.item(withTitle: "Tools")?.submenu, title: "Add Note", key: "n", modifiers: [.command, .control])
        if let file = main.item(withTitle: "File")?.submenu {
            let recent = NSMenu(title: "Open Recent")
            recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
            let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            file.insertItem(recentItem, at: 1)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = main.item(withTitle: "Help")?.submenu
    }

    private static func arrow(_ key: Int) -> String {
        String(UnicodeScalar(UInt32(key))!)
    }

    private func hideShortcutAlias(in menu: NSMenu?, title: String, key: String, modifiers: NSEvent.ModifierFlags = .control) {
        guard let menu else { return }
        guard let alias = menu.items.first(where: { $0.title == title && $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }) else { return }
        alias.isHidden = true
        alias.allowsKeyEquivalentWhenHidden = true
    }

    private func menu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func tagged(_ title: String, _ action: Selector, _ tag: Int) -> NSMenuItem {
        let entry = item(title, action)
        entry.tag = tag
        return entry
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func separator() -> NSMenuItem { .separator() }
}

enum WordLibrary {
    static func export(csv: Bool) -> (String, [String]) {
        let fs = LocalFileSystem()
        let index = LibraryIndex.load(from: AppPaths.indexFile, fs: fs)
        var books: [ExportBook] = []
        var missing: [String] = []
        for entry in index.documents {
            guard fs.isDirectory(entry.sidecarPath) else {
                missing.append(entry.title)
                continue
            }
            books.append(ExportBook(title: entry.title, words: words(in: entry.sidecarPath, fs: fs)))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = formatter.string(from: Date())
        let text = csv ? WordExport.csv(books: books) : WordExport.markdown(books: books, date: date)
        return (text, missing)
    }

    private static func words(in directory: String, fs: FileSystem) -> [WordEntry] {
        if let package = try? SidecarPackage.read(from: directory, fs: fs), !package.words.words.isEmpty {
            return package.words.words
        }
        for relative in ["learner/vocabulary.md", "words.md"] {
            guard let text = try? fs.readString(Paths.join(directory, relative)) else { continue }
            let entries = VocabularyFile.parse(text)
            if entries.isEmpty { continue }
            return entries.map { entry in
                WordEntry(
                    id: entry.readerOwned ? entry.id : "hand_\(entry.word.lowercased())",
                    word: entry.word,
                    definition: entry.meaning,
                    explanation: entry.plainLanguage,
                    lookups: [LookupEntry(id: "l_\(entry.id)", section: entry.chapter.map { "Chapter \($0)" }, quote: entry.word, sentence: entry.bookContext, date: entry.added)]
                )
            }
        }
        return []
    }
}
