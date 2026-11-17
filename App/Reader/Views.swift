import AppKit
import PDFKit
import ReaderCore
import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reader").font(.largeTitle.weight(.semibold))
            Text("Open a PDF or EPUB. Notes, words, and highlights stay in a .reader package next to the book.")
                .foregroundStyle(.secondary)
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("o")
            if !NSDocumentController.shared.recentDocumentURLs.isEmpty {
                Text("Recent").font(.headline)
                ForEach(NSDocumentController.shared.recentDocumentURLs.prefix(6), id: \.path) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SidebarView: View {
    @ObservedObject var session: ReaderSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = session.notice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.caption)
                    HStack {
                        if session.needsReanchor {
                            Button("Re-anchor") { session.reanchor() }
                        }
                        if session.offerMoveTo != nil {
                            Button("Move notes") { session.acceptMove() }
                        }
                        Button("Dismiss") { session.dismissNotice() }
                    }
                }
                .padding(8)
            }
            switch session.sidebar {
            case .hidden, .contactSheet:
                Text(session.sidebar == .contactSheet ? "Contact sheet" : "Sidebar hidden")
                    .font(.caption).foregroundStyle(.secondary).padding()
            case .thumbnails:
                thumbnailList
            case .tableOfContents:
                outlineList
            case .highlightsAndNotes:
                annotationList
            case .bookmarks:
                bookmarkList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var thumbnailList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let document = session.pdfDocument {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        VStack(spacing: 6) {
                            PageThumb(document: document, index: index)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(0.72, contentMode: .fit)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .stroke(session.page == index + 1 ? Color.accentColor : Color.black.opacity(0.12), lineWidth: session.page == index + 1 ? 2 : 1)
                                )
                                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            Text("\(index + 1)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .onTapGesture { jump(page: index + 1) }
                    }
                } else {
                    ForEach(Array((session.epub?.spine ?? []).enumerated()), id: \.offset) { index, item in
                        Text(item.title).font(.callout).padding(.vertical, 6)
                            .onTapGesture { jump(page: index + 1) }
                    }
                }
            }
            .padding(10)
        }
    }

    private var outlineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if session.outline.isEmpty {
                    Text("This document has no table of contents.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.outline) { row in
                    Text(row.title)
                        .font(.callout)
                        .padding(.leading, CGFloat(row.depth) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if let page = row.page { jump(page: page) } else if let cfi = row.cfi { jumpEPUB(cfi) } }
                }
            }
            .padding(10)
        }
    }

    private var annotationList: some View {
        AnnotationBrowser(session: session) { item in jumpAnnotation(item) }
            .padding(8)
    }

    private func jumpAnnotation(_ item: Annotation) {
        guard let controller = NSApp.keyWindow?.windowController as? ReaderWindowController else { return }
        controller.reveal(ReadingPosition(page: item.page, cfi: item.cfi, section: item.section, quote: item.quote))
    }

    private var bookmarkList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bookmarks").font(.headline)
                if session.bookmarks.isEmpty {
                    Text("Press ⌘D to bookmark this page.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.bookmarks) { bookmark in
                    VStack(alignment: .leading) {
                        Text(bookmark.title).font(.callout)
                        Text(bookmark.page.map { "p. \($0)" } ?? bookmark.section ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .onTapGesture { if let page = bookmark.page { jump(page: page) } }
                }
                Text("Marks").font(.headline).padding(.top, 8)
                Text("Lowercase marks stay in this book. Uppercase marks open whichever book they were set in. Press m, then a key. Press `, then the key to jump.").font(.caption).foregroundStyle(.secondary)
                ForEach(session.marks) { mark in
                    markRow(mark, global: false)
                }
                ForEach(session.globalMarks) { mark in
                    markRow(mark, global: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markRow(_ mark: MarkEntry, global: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(mark.symbol)  \(mark.position.section ?? mark.position.page.map { "p. \($0)" } ?? "")")
                .font(.callout.monospaced())
            Text(global ? (mark.documentTitle ?? "Another book") : "This book")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onTapGesture {
            if global, mark.bookFingerprint != session.fingerprint, let path = mark.bookPath {
                NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, _ in }
            } else if let page = mark.position.page {
                jump(page: page)
            }
        }
    }

    private func jump(page: Int) {
        session.recordJump(from: ReadingPosition(page: session.page, zoom: session.zoom, section: session.sectionTitle), to: ReadingPosition(page: page))
        session.page = page
        session.onPageChange?()
        if let controller = NSApp.keyWindow?.windowController as? ReaderWindowController {
            controller.reveal(ReadingPosition(page: page))
        }
    }

    private func jumpEPUB(_ href: String) {
        if let index = session.epub?.spine.firstIndex(where: { href.hasPrefix($0.href) || $0.href == href }) {
            jump(page: index + 1)
        }
    }
}

struct PageThumb: NSViewRepresentable {
    var document: PDFDocument
    var index: Int

    func makeNSView(context: Context) -> ThumbView { ThumbView() }
    func updateNSView(_ view: ThumbView, context: Context) {
        view.page = document.page(at: index)
        view.needsDisplay = true
    }
}

final class ThumbView: NSView {
    var page: PDFPage?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let page else { return }
        let pageBox = page.bounds(for: .mediaBox)
        guard pageBox.width > 0, pageBox.height > 0 else { return }
        let aspect = pageBox.width / pageBox.height
        var target = bounds.insetBy(dx: 4, dy: 4)
        if target.width / max(target.height, 1) > aspect {
            let width = target.height * aspect
            target.origin.x += (target.width - width) / 2
            target.size.width = width
        } else {
            let height = target.width / aspect
            target.origin.y += (target.height - height) / 2
            target.size.height = height
        }
        let image = page.thumbnail(of: target.size, for: .mediaBox)
        image.draw(in: target)
    }
}

struct ContactSheetView: View {
    var document: PDFDocument
    @ObservedObject var session: ReaderSession
    var select: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                ForEach(0..<document.pageCount, id: \.self) { index in
                    VStack {
                        PageThumb(document: document, index: index)
                            .aspectRatio(pageAspect(index), contentMode: .fit)
                            .frame(height: 180)
                        Text("\(index + 1)").font(.caption)
                    }
                    .onTapGesture { select(index + 1) }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pageAspect(_ index: Int) -> CGFloat {
        let box = document.page(at: index)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        return box.width / max(box.height, 1)
    }
}

struct EPUBContactSheet: View {
    @ObservedObject var session: ReaderSession
    var select: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                ForEach(Array((session.epub?.spine ?? []).enumerated()), id: \.offset) { index, item in
                    Text(item.title).frame(maxWidth: .infinity, minHeight: 80).padding().background(Color(nsColor: .controlBackgroundColor)).onTapGesture { select(index) }
                }
            }
            .padding(20)
        }
    }
}

struct RightPanelView: View {
    @ObservedObject var session: ReaderSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Panel", selection: $session.panelTab) {
                Text("Notes \(session.annotations.count)").tag(PanelTab.notes)
                Text("Words \(session.words.count)").tag(PanelTab.words)
                Text("Ask AI").tag(PanelTab.askAI)
            }
            .pickerStyle(.segmented)
            .padding(8)
            .labelsHidden()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch session.panelTab {
                    case .notes, .highlights:
                        AnnotationBrowser(session: session) { item in jumpAnnotation(item) }
                            .frame(minHeight: 280)
                    case .words: words
                    case .askAI: ask
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func jumpAnnotation(_ item: Annotation) {
        guard let controller = NSApp.keyWindow?.windowController as? ReaderWindowController else { return }
        controller.reveal(ReadingPosition(page: item.page, cfi: item.cfi, section: item.section, quote: item.quote))
    }

    private var words: some View {
        WordList(session: session)
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection = session.selection, !selection.text.isEmpty {
                HStack {
                    Text("“\(selection.text)”").font(.callout).italic().lineLimit(3)
                    Spacer()
                    Button("×") { session.selection = nil; session.chat = [] }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Explain") { session.withSelection { session.ask(purpose: .explainSimply) } }
                Button("Summarize") { session.withSelection { session.ask(purpose: .summarizeSection) } }
                Button("Define Terms") { session.withSelection { session.ask(purpose: .ask("Define the difficult terms in this passage.")) } }
                if session.tutorAvailable {
                    Button("Learn") { session.withSelection { session.askTutor(command: .learn, question: session.question) } }
                    Button("Review") { session.withSelection { session.askTutor(command: .review, question: session.question) } }
                    Button("Wrap") { session.withSelection { session.askTutor(command: .wrap, question: session.question) } }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if session.chat.isEmpty {
                        ContentUnavailableView("Ask about this passage", systemImage: "text.bubble", description: Text("Passages are sent to the chosen provider when you ask."))
                    }
                    ForEach(session.chat) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text).textSelection(.enabled).padding(8).background(line.mine ? Color.accentColor.opacity(0.15) : Color(nsColor: .quaternaryLabelColor).opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 8))
                            if !line.mine, !line.text.isEmpty {
                                HStack {
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(line.text, forType: .string)
                                    }
                                    Button("Save as Note") {
                                        session.answer = line.text
                                        session.saveAnswerAsNote()
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            TextEditor(text: $session.question)
                .font(.body)
                .frame(minHeight: 44, maxHeight: 80)
                .onKeyPress(.return) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    session.withSelection { session.askCurrentQuestion() }
                    return .handled
                }
            HStack {
                Picker("Provider", selection: $session.provider) {
                    ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                if session.asking { Button("Stop") { session.stopAsk() } }
            }
        }
    }

    private func conceptHelp(_ concept: Concept) -> String {
        var lines: [String] = []
        if let claim = concept.claim { lines.append("Claim: \(claim)") }
        if let trap = concept.trap { lines.append("Trap: \(trap)") }
        return lines.joined(separator: "\n")
    }
}

struct WordList: View {
    @ObservedObject var session: ReaderSession
    @State private var query = ""
    @State private var sort = "recent"
    @State private var filter = "all"

    var body: some View {
        let rows = ordered
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search words", text: $query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $sort) {
                    Text("Recent").tag("recent")
                    Text("A–Z").tag("alpha")
                    Text("Page").tag("page")
                }.labelsHidden()
                Picker("Filter", selection: $filter) {
                    Text("All").tag("all")
                    Text("Learning").tag("learning")
                    Text("Learned").tag("learned")
                }.labelsHidden()
            }
            if rows.isEmpty {
                ContentUnavailableView("No words yet", systemImage: "character.book.closed", description: Text("Look up a word with ⌃⌘D or Force Click. It lands here with its sentence."))
            } else {
                List {
                    ForEach(rows) { word in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(word.word).font(.body.weight(.semibold))
                            Text(word.definition).font(.callout).lineLimit(2)
                            if let sentence = word.lookups.first?.sentence {
                                Text(sentence).font(.caption).lineLimit(1)
                            }
                            Text(word.lookups.first?.page.map { "p. \($0)" } ?? word.lookups.first?.section ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let page = word.lookups.first?.page, let controller = NSApp.keyWindow?.windowController as? ReaderWindowController {
                                controller.reveal(ReadingPosition(page: page, quote: word.lookups.first?.sentence))
                            }
                        }
                        .contextMenu {
                            Button("Copy") { copy(word.word) }
                            Button("Copy with Sentence") { copy("\(word.word) — \(word.lookups.first?.sentence ?? "")") }
                            Button(word.learned ? "Mark Learning" : "Mark Learned") { session.setLearned(id: word.id, learned: !word.learned) }
                            Button("Remove") { session.deleteWord(id: word.id) }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { rows[$0].id }.forEach { session.deleteWord(id: $0) }
                    }
                }
            }
        }
    }

    private var ordered: [WordEntry] {
        var rows = session.words.filter { word in
            (query.isEmpty || word.word.localizedCaseInsensitiveContains(query) || word.definition.localizedCaseInsensitiveContains(query))
                && (filter == "all" || (filter == "learned" ? word.learned : !word.learned))
        }
        switch sort {
        case "alpha": rows.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        case "page": rows.sort { ($0.lookups.first?.page ?? Int.max) < ($1.lookups.first?.page ?? Int.max) }
        default: break
        }
        return rows
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct LookupCard: View {
    @ObservedObject var session: ReaderSession
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lookup = session.lookup {
                Text(lookup.word).font(.title2.weight(.semibold))
                if let times = session.words.first(where: { $0.word.caseInsensitiveCompare(lookup.word) == .orderedSame })?.count, times > 1 {
                    Text("Looked up \(times)×").font(.caption).foregroundStyle(.secondary)
                }
                Text("Dictionary").font(.caption).foregroundStyle(.secondary)
                Text(lookup.definition)
                Text(lookup.busy ? "Explaining…" : "In this passage").font(.caption).foregroundStyle(.secondary)
                Text(lookup.explanation.isEmpty ? " " : lookup.explanation)
                Text("“\(lookup.sentence)” · \(lookup.location)").font(.caption).italic()
                HStack {
                    Text("Saved to Words").font(.caption).foregroundStyle(.secondary)
                    Button("Undo") { session.undoLookup(); dismiss() }.buttonStyle(.borderless)
                    Spacer()
                    Button("Open in Dictionary") {
                        if let url = URL(string: "dict://\(lookup.word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lookup.word)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

struct SettingsView: View {
    @State private var settings = SettingsStore.load()
    @State private var openAIKey = KeychainStore.load(account: "openai") ?? ""
    @State private var anthropicKey = KeychainStore.load(account: "anthropic") ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show the annotation bar when selecting text", isOn: $settings.showSelectionBar)
            }
            Section("Default") {
                Picker("Provider", selection: $settings.defaultProvider) {
                    ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("ChatGPT is the default for Ask AI and for word explanations.").font(.caption).foregroundStyle(.secondary)
            }
            Section("API keys") {
                SecureField("OpenAI API key", text: $openAIKey)
                TextField("OpenAI model", text: $settings.openAIModel)
                SecureField("Anthropic API key", text: $anthropicKey)
                TextField("Anthropic model", text: $settings.anthropicModel)
                Text("Keys are stored in the login keychain under \(KeychainStore.service). They are not written into settings.json.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal providers") {
                TextField("claude path", text: Binding(get: { settings.claudeCLIPath ?? "" }, set: { settings.claudeCLIPath = $0.isEmpty ? nil : $0 }))
                TextField("codex path", text: Binding(get: { settings.codexCLIPath ?? "" }, set: { settings.codexCLIPath = $0.isEmpty ? nil : $0 }))
                Button("Detect installed CLIs") {
                    settings.claudeCLIPath = CLILocator.locate("claude")
                    settings.codexCLIPath = CLILocator.locate("codex")
                }
                Text("A saved claude path overrides detection. Otherwise Reader looks in ~/.local/bin, Homebrew, /usr/local/bin, then `zsh -lc 'command -v claude'`.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Look up") {
                Toggle("Use the default provider for word explanations", isOn: $settings.lookupUsesDefault)
                if !settings.lookupUsesDefault {
                    Picker("Look up provider", selection: $settings.lookupProvider) {
                        ForEach(ProviderID.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Suggested notes", isOn: $settings.suggestedNotes)
                Text("Suggested notes stay off until you turn them on. Reader does not write a suggestion unless you ask.").font(.caption).foregroundStyle(.secondary)
            }
            Button(saved ? "Saved" : "Save") {
                if !openAIKey.isEmpty { KeychainStore.save(account: "openai", secret: openAIKey) }
                if !anthropicKey.isEmpty { KeychainStore.save(account: "anthropic", secret: anthropicKey) }
                SettingsStore.save(settings)
                saved = true
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 560)
    }
}

struct WordsBrowser: View {
    var books: [LibraryEntry]
    @State private var query = ""
    @State private var sort = "page"
    @State private var book = "All"
    @State private var selected: String?

    var body: some View {
        let rows = gathered.filter { row in
            (book == "All" || row.book == book) && (query.isEmpty || row.word.localizedCaseInsensitiveContains(query) || row.definition.localizedCaseInsensitiveContains(query))
        }
        VStack {
        Picker("Book", selection: $book) {
            Text("All books").tag("All")
            ForEach(Array(Set(books.map(\.title))).sorted(), id: \.self) { title in
                Text(title).tag(title)
            }
        }
        HSplitView {
            List(rows, id: \.word, selection: $selected) { row in
                VStack(alignment: .leading) {
                    Text(row.word).font(.body.weight(.semibold))
                    Text(row.definition).font(.caption).lineLimit(2)
                    Text("\(row.book) · \(row.location)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 280)
            if let row = rows.first(where: { $0.word == selected }) ?? rows.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.word).font(.largeTitle)
                    Text(row.definition)
                    Text("“\(row.sentence)”").italic()
                    Text("\(row.book) · \(row.location)").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(rows.count) words").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export all books’ words…") { (NSApp.delegate as? AppDelegate)?.exportAllWords(nil) }
            }
            .padding(8)
        }
        }
    }

    private var gathered: [WordRow] {
        books.flatMap { entry -> [WordRow] in
            guard let package = try? SidecarPackage.read(from: entry.sidecarPath, fs: LocalFileSystem()) else { return [] }
            return package.words.words.map { word in
                let lookup = word.lookups.first
                return WordRow(word: word.word, definition: word.definition, sentence: lookup?.sentence ?? "", book: entry.title, location: lookup?.page.map { "p. \($0)" } ?? "", page: lookup?.page ?? Int.max)
            }
        }.sorted { sort == "az" ? $0.word < $1.word : $0.page < $1.page }
    }
}

private struct WordRow {
    var word: String
    var definition: String
    var sentence: String
    var book: String
    var location: String
    var page: Int
}

struct ShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Viewing shortcuts match Preview. Notes, words, and Ask AI use the Reader shortcuts. ⌘1–⌘3 stay with Continuous Scroll, Single Page, and Two Pages, so the side panel uses ⌃1–⌃4.").font(.callout).foregroundStyle(.secondary)
            List(ShortcutCatalog.rows) { row in
                HStack {
                    Text(row.title)
                    Spacer()
                    Text(row.keys).foregroundStyle(.secondary).monospaced()
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 560)
    }
}
